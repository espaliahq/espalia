# frozen_string_literal: true

# Assessment UI for the current user's own assessments, their direct
# reports' assessments (manager view), and — read-only — the assessments
# of everyone deeper in their org subtree (skip-level view).
#
# The assessment ID in URLs is the framework_id — an assessment is a
# projection derived from the PersonDevelopment event stream, not a
# separate entity.
#
class AssessmentsController < ApplicationController
  include AssessmentVisibility

  # Skip-level subtrees can be large for senior managers — the section is
  # paginated rather than rendering an unbounded card grid.
  SKIP_LEVEL_PAGE_SIZE = 12

  before_action :require_person
  before_action :set_assignment, only: [ :show, :matrix, :scoring, :capability_card ]

  # GET /assessments
  def index
    authorize PersonFrameworkAssignment, :index?
    @page_title = "My Assessments"
    @own_assignments = PersonFrameworkAssignment.for_person(current_person.id)
      .includes(:framework, :role, :level)
    reviewable = Assessments::ReviewableAssignments.new(current_person)
    @report_assignments = reviewable.team
    @skip_level_pagy, @skip_level_assignments = pagy(
      reviewable.skip_level, limit: SKIP_LEVEL_PAGE_SIZE, page_key: "skip_page"
    )
    @report_people = Person.where(
      id: (@report_assignments.map(&:person_id) + @skip_level_assignments.map(&:person_id)).uniq
    ).index_by(&:id)

    all_assignments = @own_assignments.to_a + @report_assignments.to_a + @skip_level_assignments.to_a
    cycle_pairs = all_assignments.map { |a| [ a.framework_id, a.person_id ] }
    @open_cycles = AssessmentCycle.open_cycles_for(cycle_pairs)
    @card_statuses = build_card_statuses(@open_cycles)
    # The person's own and their team's, as `assessments_mine` returns them —
    # an exploration is a conversation between the two, not a list for the
    # wider chain.
    @explorations = Assessments::OpenExplorations.for(
      @own_assignments.to_a + @report_assignments.to_a, progress_for: @own_assignments, open_cycles: @open_cycles
    )

    render Views::Assessments::IndexView.new(
      assignments: @own_assignments,
      report_assignments: @report_assignments,
      skip_level_assignments: @skip_level_assignments,
      skip_level_pagy: @skip_level_pagy,
      report_people: @report_people,
      open_cycles: @open_cycles,
      card_statuses: @card_statuses,
      explorations: @explorations,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /assessments/:id
  def show
    authorize @assignment
    load_assessment_data
    @page_title = manager_viewing? ? "#{@assessee.name} · Assessment" : "My Assessment"
    active_category_id = resolve_active_category_id
    context = assessment_context
    policy = assignment_policy
    activity_entries = load_activity_entries
    can_relink_others = viewer_can_relink_others_evidence?
    if manager_viewing?
      render Views::Assessments::ManagerShowView.new(
        assignment: @assignment,
        assessee: @assessee,
        framework: @framework,
        matrix_data: @matrix_data,
        active_category_id: active_category_id,
        expanded_capability_id: params[:capability],
        expanded_level_ordinal: focused_level_ordinal_param,
        selected_levels: selected_levels_param,
        context: context,
        # Alignment is per role (ADR-22): the record's milestones on the
        # record, a lens role's on that lens at the level its conversation
        # is about. Never on another level of the home ladder: the
        # completion control counts the level it is rendered against.
        can_start_alignment: lens.home? && policy.start_alignment?,
        can_complete_alignment: milestone_lens? && policy.complete_alignment?(role_id: lens_role_id),
        can_reopen_alignment: milestone_lens? && policy.reopen_alignment?(role_id: lens_role_id),
        can_start_lens_alignment: !lens.home_role? && policy.start_alignment?(role_id: lens_role_id),
        lens_viewer: lens_viewer(policy),
        viewer_person_id: current_person&.id,
        can_create_evidence: viewer_can_create_evidence?,
        can_request_evidence: viewer_can_request_evidence?,
        can_relink_others_evidence: can_relink_others,
        can_comment: viewer_can_comment?,
        viewer_is_tenant_admin: viewer_is_tenant_admin?,
        activity_entries: activity_entries,
        exploration: lens_exploration,
        can_explore: policy.start_exploration?,
        can_manage_delegates: policy.delegate_manager_rating?,
        active_delegations: load_active_delegations(policy),
        candidate_delegates: load_candidate_delegates(policy),
        viewer_can_rate: policy.rating_participant?,
        unplaced_feedback_count: unplaced_feedback_count,
        user: current_user,
        current_tenant: ActsAsTenant.current_tenant,
        tenants: current_user_tenants
      )
    else
      render Views::Assessments::ShowView.new(
        assignment: @assignment,
        framework: @framework,
        matrix_data: @matrix_data,
        active_category_id: active_category_id,
        expanded_capability_id: params[:capability],
        expanded_level_ordinal: focused_level_ordinal_param,
        selected_levels: selected_levels_param,
        context: context,
        viewer_person_id: current_person&.id,
        can_create_evidence: viewer_can_create_evidence?,
        can_request_evidence: viewer_can_request_evidence?,
        can_relink_others_evidence: can_relink_others,
        can_comment: viewer_can_comment?,
        viewer_is_tenant_admin: viewer_is_tenant_admin?,
        activity_entries: activity_entries,
        exploration: lens_exploration,
        can_explore: policy.start_exploration?,
        unplaced_feedback_count: unplaced_feedback_count,
        user: current_user,
        current_tenant: ActsAsTenant.current_tenant,
        tenants: current_user_tenants
      )
    end
  end

  # GET /assessments/:id/matrix
  def matrix
    authorize @assignment, :matrix?
    load_assessment_data
    render Views::Assessments::AssessmentMatrixFrameView.new(**matrix_view_args), layout: false
  end

  # GET /assessments/:id/capability_card
  #
  # One card, rendered through the same path as the matrix frame and
  # narrowed to `?capability=`, as a Turbo Stream replacing it in place.
  def capability_card
    authorize @assignment, :matrix?
    load_assessment_data
    stable_id = params.expect(:capability)
    return head(:not_found) unless capability_in_matrix?(stable_id)

    # The ring is the client's to place: focus may have moved on by the time
    # this lands, so the card arrives unfocused and the controller re-stamps it.
    args = matrix_view_args.except(:framework, :assignment, :active_category_id)
      .merge(expanded_capability_id: nil, expanded_level_ordinal: nil)
    html = render_to_string(
      Views::Assessments::AssessmentMatrix.new(**args, assessment_id: @assignment.id, only_capability: stable_id),
      layout: false
    )
    render turbo_stream: turbo_stream.replace(Views::Assessments::CapabilityCard.dom_id_for(stable_id), html)
  end

  # GET /assessments/:id/scoring
  def scoring
    authorize @assignment, :scoring?
    load_assessment_data
    render Views::Assessments::ScoringPanelFrameView.new(
      matrix_data: @matrix_data,
      context: assessment_context,
      viewer_is_manager: manager_viewing?,
      active_category_id: resolve_active_category_id,
      assessment_id: @assignment.id,
      assessee_name: manager_viewing? ? @assessee&.name : nil,
      viewer_can_rate: assignment_policy.rating_participant?
    ), layout: false
  end

  private

  def require_person
    return if current_person

    # A Turbo Frame fetch (matrix / scoring reload) can't follow a redirect —
    # render the frame with a reload prompt instead of silently breaking it.
    if turbo_frame_request?
      render_turbo_frame_recovery("Your session has changed — please reload.")
    else
      redirect_to root_path, alert: "No person profile linked to your account."
    end
  end

  # The role and level the page is read against (`as_role` / `as_level`),
  # resolved once per request and only after `authorize`, so a pair the
  # framework doesn't have is a 404 to a permitted viewer and nobody else.
  #
  # @return [Assessments::Lens]
  # @raise [Assessments::Lens::NotFound]
  def lens
    @lens ||= Assessments::Lens.resolve(assignment: @assignment, as_role: params[:as_role], as_level: params[:as_level])
  end

  def set_assignment
    return unless current_person

    @assignment = PersonFrameworkAssignment.find(params.expect(:id))
    @framework = FrameworkState::Framework.find_by!(framework_id: @assignment.framework_id)
    @assessee = Person.find_by(id: @assignment.person_id) if manager_viewing?
  rescue ActiveRecord::RecordNotFound
    if turbo_frame_request?
      render_turbo_frame_recovery("This assessment is no longer available — please reload.")
    else
      redirect_to assessments_path, alert: "Assessment not found."
    end
  end

  # The matrix frame's arguments, shared with the single-card render so the
  # two can't drift.
  #
  # @return [Hash]
  def matrix_view_args
    {
      framework: @framework,
      matrix_data: @matrix_data,
      assignment: @assignment,
      context: assessment_context,
      viewer_is_manager: manager_viewing?,
      active_category_id: resolve_active_category_id,
      expanded_capability_id: params[:capability],
      expanded_level_ordinal: focused_level_ordinal_param,
      selected_levels: selected_levels_param,
      viewer_person_id: current_person&.id,
      can_create_evidence: viewer_can_create_evidence?,
      can_request_evidence: viewer_can_request_evidence?,
      can_relink_others_evidence: viewer_can_relink_others_evidence?,
      can_comment: viewer_can_comment?,
      viewer_is_tenant_admin: viewer_is_tenant_admin?
    }
  end

  def capability_in_matrix?(stable_id)
    @matrix_data[:categories].any? { |c| c[:capabilities].any? { |cap| cap[:capability].stable_id == stable_id } }
  end

  # Whether current_person is viewing a direct report's assessment.
  # Delegates to the shared {AssessmentVisibility#viewer_is_manager?} so the
  # page, frame, and Turbo Stream renders all derive the viewer-side flag
  # from one predicate and can't drift apart.
  #
  # @return [Boolean]
  def manager_viewing?
    viewer_is_manager?
  end

  # Returns the assessment context based on the viewer's relationship and
  # the cycle's lifecycle. Once the manager has formally started alignment
  # (cycle status `aligning` or `aligned`), both parties view the assessment
  # in alignment mode automatically — there is no opt-in/opt-out toggle.
  #
  # @return [Symbol] :self, :manager, or :alignment
  def assessment_context
    @assessment_context ||=
      Assessments::ViewerContext.for(assignment: @assignment, authorization: pundit_user, lens: lens)
  end

  def load_assessment_data
    @matrix_data = Assessments::MatrixDataBuilder.for_lens(
      lens: lens,
      context: assessment_context,
      viewer_person_id: current_person&.id,
      viewer_sees_all_evidence: viewer_sees_all_evidence?
    )
    apply_viewer_rating_lock
  end

  # View-only manager-side viewers (manager-chain ancestors who are neither
  # the recorded reporting manager nor an active rating delegate) get static
  # rating pills — the rating policies would reject their POSTs, so no
  # interactive affordance should render. Rating-capable viewers keep the
  # lifecycle-derived flags untouched.
  def apply_viewer_rating_lock
    return unless manager_viewing?

    @matrix_data[:individual_ratings_frozen] = true unless assignment_policy.create_manager_rating?
    if assessment_context == :alignment && !assignment_policy.create_alignment_rating?
      @matrix_data[:alignment_locked] = true
    end
  end

  def assignment_policy
    @assignment_policy ||= AssessmentPolicy.new(pundit_user, @assignment)
  end

  # Whose ratings the lens banner speaks of on the manager view: the
  # reporting manager's, a delegate's, or nobody's (a view-only viewer).
  #
  # @return [Symbol] :manager, :delegate or :observer
  def lens_viewer(policy)
    return :observer unless policy.rating_participant?

    active_rating_delegate? ? :delegate : :manager
  end

  # The open exploration of the role the page is read through (ADR-22) — any
  # level of it, since one per role is open at a time. nil on the record.
  #
  # @return [AssessmentExploration, nil]
  def lens_exploration
    return nil if lens.home?

    AssessmentExploration.open_of_role(@assignment, lens.role.role_id)
  end

  # @return [String, nil] the lens role, nil on the home role
  def lens_role_id
    lens.role.role_id unless lens.home_role?
  end

  # Whether the page is read at the level an alignment milestone counts:
  # the record itself, or a lens role at the level its conversation began.
  def milestone_lens?
    return lens.home? if lens.home_role?

    @matrix_data[:lens_alignment]&.level_ordinal == lens.level.ordinal
  end

  # `viewer_sees_all_evidence?`, `viewer_can_relink_others_evidence?`, and
  # `active_rating_delegate?` are provided by the shared {AssessmentVisibility}
  # concern so every assessment controller (page, activity frame, evidence
  # frame) applies the same rule.

  # Whether the current viewer is permitted to record evidence on this
  # assessment. V1 allows any tenant member with a Person to record peer
  # evidence — see {EvidencePolicy#create?}.
  def viewer_can_create_evidence?
    return false unless current_person

    EvidencePolicy.new(pundit_user, @assignment).create?
  end

  # Whether to render the per-cell "Request evidence" affordance — same
  # population as who may create a request (assessee / manager chain / active
  # rating delegate / tenant admin), enforced again server-side on submit.
  def viewer_can_request_evidence?
    return false unless current_person

    EvidenceRequestPolicy.new(pundit_user, @assignment).request?
  end

  # Feedback given about this person with no cell yet. Shown as a notice to
  # the viewers who see all the assessment's evidence; a peer, who sees only
  # their own items, is never told what others gave.
  def unplaced_feedback_count
    return 0 unless viewer_sees_all_evidence?

    EvidenceItem.unplaced.for_person(@assignment.person_id).for_framework(@assignment.framework_id).count
  end

  # Whether the current viewer is permitted to post comments on this
  # assessment. V1 allows any tenant member with a Person to comment —
  # the conversation lane is intentionally broader than the evidence
  # lane. Authority for editing/deleting is gated per-card in the view.
  def viewer_can_comment?
    return false unless current_person

    PersonDevelopmentCommentPolicy.new(pundit_user, @assignment).create?
  end

  # Tenant admins gain a delete-only override for moderation. Not a
  # general edit override — only the author can rewrite their own words.
  def viewer_is_tenant_admin?
    current_user&.global_admin? || current_tenant_user&.admin? || false
  end

  # Loads the activity feed entries the current viewer is permitted to
  # see. Identical visibility rules to the matrix's evidence list +
  # rating-event privacy gates from ActivityFeedQuery.
  def load_activity_entries
    return [] unless current_person

    Assessments::ActivityFeedQuery.new(
      assignment: @assignment,
      context: assessment_context,
      viewer_person_id: current_person.id,
      viewer_sees_all: viewer_sees_all_evidence?,
      alignment_started: alignment_started?,
      disclosure: (@matrix_data[:disclosure] if @assignment.person_id == current_person.id)
    ).call
  end

  def alignment_started?
    %w[aligning aligned].include?(@assignment.current_open_cycle_participation&.status)
  end

  # Active delegations for the assessment, loaded once and only when the viewer
  # may manage them (avoids extra queries for the common case).
  #
  # @param policy [AssessmentPolicy]
  # @return [Array<ManagerAssessmentDelegation>]
  def load_active_delegations(policy)
    return @active_delegations if defined?(@active_delegations)

    @active_delegations =
      if policy.delegate_manager_rating?
        ManagerAssessmentDelegation.active.for_assignment(@assignment).includes(:delegate).to_a
      else
        []
      end
  end

  # Tenant people eligible to receive a delegation.
  #
  # @param policy [AssessmentPolicy]
  # @return [Array<Person>]
  def load_candidate_delegates(policy)
    return [] unless policy.delegate_manager_rating?

    ManagerAssessmentDelegation
      .candidate_people(assignment: @assignment, actor_person_id: current_person.id).to_a
  end

  # Builds per-card status for the index, keyed by [framework_id, person_id].
  # Combines the projected per-side completion (AssessmentCycleProgress) with a
  # single cheap "any rating exists per side" query so the view can render the
  # Not started / In progress / Complete tri-state without per-card work.
  #
  # @param open_cycles [Hash{Array(String,String) => AssessmentCycle}]
  # @return [Hash{Array(String,String) => Hash}]
  def build_card_statuses(open_cycles)
    return {} if open_cycles.empty?

    cycle_ids = open_cycles.values.map(&:cycle_id)
    person_ids = open_cycles.keys.map(&:last)

    progress = AssessmentCycleProgress
      .where(cycle_id: cycle_ids, person_id: person_ids)
      .index_by { |p| [ p.cycle_id, p.person_id ] }
    # Per side: "any" (a value exists — carried or human) and "human" (the
    # person touched the side this cycle: rated, revised, confirmed, or
    # explicitly cleared — provenance "human"; nil provenance counts as
    # human for legacy rows). The view derives the tri+1-state from these:
    # Complete / In progress (human touch) / To confirm (all carried) /
    # Not started. Only the assessed role's cells count: rating a cell the
    # role doesn't read hasn't started this assessment.
    rated = open_cycles.group_by { |_, cycle| cycle }.each_with_object({}) do |(cycle, entries), h|
      h.merge!(card_rating_counts(cycle, entries.map { |(_, person_id), _| person_id }))
    end
    lens_alignments = Assessments::LensAlignments.for(cycle_ids: cycle_ids, person_ids: person_ids)

    open_cycles.each_with_object({}) do |((framework_id, person_id), cycle), statuses|
      prog = progress[[ cycle.cycle_id, person_id ]]
      any = rated[[ cycle.cycle_id, person_id ]] || {}
      statuses[[ framework_id, person_id ]] = {
        status: prog&.status,
        self_complete: prog&.self_completed_at.present?,
        manager_complete: prog&.manager_completed_at.present?,
        self_any: any[:self_any] || false,
        manager_any: any[:manager_any] || false,
        self_human: any[:self_human] || false,
        manager_human: any[:manager_human] || false,
        lens_alignments: lens_alignments.fetch([ cycle.cycle_id, person_id ], [])
      }
    end
  end

  # One cycle's per-person "any" / "human" flags for each rating side.
  #
  # @return [Hash{Array(String, String) => Hash}]
  def card_rating_counts(cycle, person_ids)
    AssessmentLevelRating
      .where(cycle_id: cycle.cycle_id)
      .within(Assessments::RoleScope.for_people(
        cycle_id: cycle.cycle_id, framework_id: cycle.framework_id, person_ids: person_ids
      ))
      .group(:cycle_id, :person_id)
      .pluck(
        :cycle_id, :person_id,
        Arel.sql("COUNT(*) FILTER (WHERE self_rated_frequency IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE manager_rated_frequency IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE self_rating_source = 'human' " \
                 "OR (self_rated_frequency IS NOT NULL AND self_rating_source IS NULL))"),
        Arel.sql("COUNT(*) FILTER (WHERE manager_rating_source = 'human' " \
                 "OR (manager_rated_frequency IS NOT NULL AND manager_rating_source IS NULL))")
      )
      .each_with_object({}) do |(cid, pid, self_n, mgr_n, self_h, mgr_h), h|
        h[[ cid, pid ]] = { self_any: self_n.positive?, manager_any: mgr_n.positive?,
                            self_human: self_h.positive?, manager_human: mgr_h.positive? }
      end
  end

  # Cell-level focus param. Only meaningful when paired with `?capability=`;
  # the matrix view stamps it on the expanded `<tr>` so the matrix Stimulus
  # controller can resurface cell focus on connect (deep-link / broadcast
  # reload).
  #
  # @return [Integer, nil]
  def focused_level_ordinal_param
    raw = params[:level_ordinal]
    return nil if raw.blank?

    Integer(raw)
  rescue ArgumentError
    nil
  end

  # Per-capability selected-level map: `{ capability_stable_id => level_ordinal }`.
  #
  # Each capability card's expansion panel renders the level the viewer last
  # selected for THAT capability, independently — so a selection persists across
  # scrolling, rating, and broadcast reloads instead of every card snapping back
  # to the current level (see assessments.md). Parsed from `?levels[<id>]=<n>`.
  #
  # The legacy single-focus pair (`?capability=&level_ordinal=`) is folded in so
  # deep-links, the Continue CTA, and activity-feed navigation still render the
  # focused card at the requested level. Unknown stable_ids are harmless — each
  # card looks itself up, so a key matching no capability is simply never read.
  #
  # @return [Hash{String => Integer}]
  def selected_levels_param
    result = {}
    # `levels` is a hash with dynamic capability-stable-id keys → permit it as a
    # whole-hash param (scalar values), then coerce each ordinal to an Integer.
    raw = params.permit(levels: {}).to_h["levels"]
    if raw.is_a?(Hash)
      raw.each do |stable_id, ordinal|
        next if stable_id.blank?

        ord = Integer(ordinal, exception: false)
        result[stable_id.to_s] = ord if ord
      end
    end

    # The explicit focus pair is the most recent deliberate selection, so it
    # takes precedence over any map entry for the same capability on a deep-link.
    if params[:capability].present? && focused_level_ordinal_param
      result[params[:capability].to_s] = focused_level_ordinal_param
    end

    result
  end

  # Resolves the active category ID from params, defaulting to the first category.
  #
  # @return [String, nil]
  def resolve_active_category_id
    return params[:category] if params[:category].present? &&
      @matrix_data[:categories].any? { |c| c[:category].category_id == params[:category] }

    @matrix_data[:categories].first&.dig(:category)&.category_id
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end

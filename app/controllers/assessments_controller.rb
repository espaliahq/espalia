# frozen_string_literal: true

# Assessment UI for the current user's own assessments and their
# direct reports' assessments (manager view).
#
# The assessment ID in URLs is the framework_id — an assessment is a
# projection derived from the PersonDevelopment event stream, not a
# separate entity.
#
class AssessmentsController < ApplicationController
  include AssessmentVisibility

  before_action :require_person
  before_action :set_assignment, only: [ :show, :matrix, :scoring ]

  # GET /assessments
  def index
    authorize PersonFrameworkAssignment, :index?
    @own_assignments = PersonFrameworkAssignment.for_person(current_person.id)
      .includes(:framework, :role, :level)
    @report_assignments = load_report_assignments
    @report_people = Person.where(id: @report_assignments.map(&:person_id)).index_by(&:id)

    all_assignments = @own_assignments.to_a + @report_assignments.to_a
    cycle_pairs = all_assignments.map { |a| [ a.framework_id, a.person_id ] }
    @open_cycles = AssessmentCycle.open_cycles_for(cycle_pairs)

    render Views::Assessments::IndexView.new(
      assignments: @own_assignments,
      report_assignments: @report_assignments,
      report_people: @report_people,
      open_cycles: @open_cycles,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /assessments/:id
  def show
    authorize @assignment
    load_assessment_data
    active_category_id = resolve_active_category_id
    context = assessment_context
    policy = AssessmentPolicy.new(pundit_user, @assignment)
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
        context: context,
        can_start_alignment: policy.start_alignment?,
        can_complete_alignment: policy.complete_alignment?,
        viewer_person_id: current_person&.id,
        can_create_evidence: viewer_can_create_evidence?,
        can_relink_others_evidence: can_relink_others,
        can_comment: viewer_can_comment?,
        viewer_is_tenant_admin: viewer_is_tenant_admin?,
        activity_entries: activity_entries,
        can_manage_delegates: policy.delegate_manager_rating?,
        active_delegations: load_active_delegations(policy),
        candidate_delegates: load_candidate_delegates(policy),
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
        context: context,
        viewer_person_id: current_person&.id,
        can_create_evidence: viewer_can_create_evidence?,
        can_relink_others_evidence: can_relink_others,
        can_comment: viewer_can_comment?,
        viewer_is_tenant_admin: viewer_is_tenant_admin?,
        activity_entries: activity_entries,
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
    render Views::Assessments::AssessmentMatrixFrameView.new(
      framework: @framework,
      matrix_data: @matrix_data,
      assignment: @assignment,
      context: assessment_context,
      active_category_id: resolve_active_category_id,
      expanded_capability_id: params[:capability],
      expanded_level_ordinal: focused_level_ordinal_param,
      viewer_person_id: current_person&.id,
      can_create_evidence: viewer_can_create_evidence?,
      can_relink_others_evidence: viewer_can_relink_others_evidence?,
      can_comment: viewer_can_comment?,
      viewer_is_tenant_admin: viewer_is_tenant_admin?
    ), layout: false
  end

  # GET /assessments/:id/scoring
  def scoring
    authorize @assignment, :scoring?
    load_assessment_data
    render Views::Assessments::ScoringPanelFrameView.new(
      matrix_data: @matrix_data,
      context: assessment_context,
      active_category_id: resolve_active_category_id,
      assessment_id: @assignment.id,
      assessee_name: manager_viewing? ? @assessee&.name : nil
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

  # Whether current_person is viewing a direct report's assessment.
  #
  # @return [Boolean]
  def manager_viewing?
    @assignment.person_id != current_person.id
  end

  # Returns the assessment context based on the viewer's relationship and
  # the cycle's lifecycle. Once the manager has formally started alignment
  # (cycle status `aligning` or `aligned`), both parties view the assessment
  # in alignment mode automatically — there is no opt-in/opt-out toggle.
  #
  # @return [Symbol] :self, :manager, or :alignment
  def assessment_context
    if AssessmentPolicy.new(pundit_user, @assignment).view_alignment?
      :alignment
    else
      manager_viewing? ? :manager : :self
    end
  end

  def load_assessment_data
    role = FrameworkState::Role.find_by!(role_id: @assignment.role_id)
    categories = FrameworkState::CapabilityCategory
      .where(framework_id: @assignment.framework_id, status: "active")
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)

    @matrix_data = Assessments::MatrixDataBuilder.new(
      framework: @framework,
      role: role,
      level: FrameworkState::Level.find_by!(level_id: @assignment.level_id),
      person_id: @assignment.person_id,
      cycle_id: @assignment.current_open_cycle&.cycle_id,
      categories: categories,
      participant_status: @assignment.current_open_cycle_participation&.status,
      context: assessment_context,
      viewer_person_id: current_person&.id,
      viewer_sees_all_evidence: viewer_sees_all_evidence?
    ).build
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
      alignment_started: alignment_started?
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

  # Loads framework assignments the current person reviews: their direct
  # reports, plus any assignment they hold an active manager-rating delegation
  # for (e.g. a report seconded into their team).
  #
  # @return [ActiveRecord::Relation<PersonFrameworkAssignment>]
  def load_report_assignments
    ids = (direct_report_assignment_ids + delegated_assignment_ids).uniq
    return PersonFrameworkAssignment.none if ids.empty?

    PersonFrameworkAssignment.where(id: ids).includes(:framework, :role, :level)
  end

  def direct_report_assignment_ids
    report_ids = current_person.direct_reports.pluck(:id)
    return [] if report_ids.empty?

    PersonFrameworkAssignment.where(person_id: report_ids).ids
  end

  # Assignment ids the current person holds an active delegation to rate.
  #
  # @return [Array<String>]
  def delegated_assignment_ids
    pairs = ManagerAssessmentDelegation.active.for_delegate(current_person.id)
      .pluck(:person_id, :framework_id)
    return [] if pairs.empty?

    scope = pairs.map { |pid, fid| PersonFrameworkAssignment.where(person_id: pid, framework_id: fid) }
                 .reduce(:or)
    scope.ids
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

# frozen_string_literal: true

# Assessment UI for the current user's own assessments and their
# direct reports' assessments (manager view).
#
# The assessment ID in URLs is the framework_id — an assessment is a
# projection derived from the PersonDevelopment event stream, not a
# separate entity.
#
class AssessmentsController < ApplicationController
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
        context: context,
        can_start_alignment: policy.start_alignment?,
        can_complete_alignment: policy.complete_alignment?,
        viewer_person_id: current_person&.id,
        can_create_evidence: viewer_can_create_evidence?,
        can_relink_others_evidence: can_relink_others,
        activity_entries: activity_entries,
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
        context: context,
        viewer_person_id: current_person&.id,
        can_create_evidence: viewer_can_create_evidence?,
        can_relink_others_evidence: can_relink_others,
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
      viewer_person_id: current_person&.id,
      can_create_evidence: viewer_can_create_evidence?,
      can_relink_others_evidence: viewer_can_relink_others_evidence?
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
      assessment_id: @assignment.id
    ), layout: false
  end

  private

  def require_person
    unless current_person
      redirect_to root_path, alert: "No person profile linked to your account."
    end
  end

  def set_assignment
    return unless current_person

    @assignment = PersonFrameworkAssignment.find(params.expect(:id))
    @framework = FrameworkState::Framework.find_by!(framework_id: @assignment.framework_id)
    @assessee = Person.find_by(id: @assignment.person_id) if manager_viewing?
  rescue ActiveRecord::RecordNotFound
    redirect_to assessments_path, alert: "Assessment not found."
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
      .where(framework_id: @assignment.framework_id)
      .includes(capabilities: [ :bindings, { expectations: :illustrations } ])
      .order(:ordinal)

    @matrix_data = Assessments::MatrixDataBuilder.new(
      framework: @framework,
      role: role,
      level: FrameworkState::Level.find_by!(level_id: @assignment.level_id),
      person_id: @assignment.person_id,
      cycle_id: @assignment.current_open_cycle&.cycle_id,
      categories: categories,
      participant_status: @assignment.current_open_cycle_participant&.status,
      context: assessment_context,
      viewer_person_id: current_person&.id,
      viewer_sees_all_evidence: viewer_sees_all_evidence?
    ).build
  end

  # Memoised assessee lookup — both `viewer_sees_all_evidence?` and
  # `viewer_can_relink_others_evidence?` reach for it on the same request.
  def assessee_person
    @assessee_person ||= Person.find_by(id: @assignment.person_id)
  end

  # Whether the current viewer can see every active piece of evidence on the
  # assessment, vs only their own peer-source contributions. Mirrors the
  # gate inside {EvidencePolicy} — viewer is the assessee, anywhere in
  # the assessee's manager chain, or a tenant admin.
  def viewer_sees_all_evidence?
    return false unless current_person
    return true if current_user&.global_admin? || current_tenant_user&.admin?
    return true if @assignment.person_id == current_person.id

    assessee_person&.managed_by?(current_person) || false
  end

  # Whether the current viewer is permitted to record evidence on this
  # assessment. V1 allows any tenant member with a Person to record peer
  # evidence — see {EvidencePolicy#create?}.
  def viewer_can_create_evidence?
    return false unless current_person

    EvidencePolicy.new(pundit_user, @assignment).create?
  end

  # Whether the viewer may relink evidence they DIDN'T author. Mirrors
  # {EvidencePolicy#relink?} for the non-author paths: assessee, or
  # anywhere in their manager hierarchy. Authors always get relink on
  # their own items via {Evidence::List#can_relink?}.
  def viewer_can_relink_others_evidence?
    return false unless current_person
    return true if @assignment.person_id == current_person.id

    assessee_person&.managed_by?(current_person) || false
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
    %w[aligning aligned].include?(@assignment.current_open_cycle_participant&.status)
  end

  # Loads framework assignments for the current person's direct reports.
  #
  # @return [Array<PersonFrameworkAssignment>]
  def load_report_assignments
    report_ids = current_person.direct_reports.pluck(:id)
    return [] if report_ids.empty?

    PersonFrameworkAssignment.where(person_id: report_ids)
      .includes(:framework, :role, :level)
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

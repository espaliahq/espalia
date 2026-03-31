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
    render Views::Assessments::IndexView.new(
      assignments: @own_assignments,
      report_assignments: @report_assignments,
      report_people: @report_people,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /assessments/:id
  def show
    authorize @assignment
    load_assessment_data
    if manager_viewing?
      render Views::Assessments::ManagerShowView.new(
        assignment: @assignment,
        assessee: @assessee,
        framework: @framework,
        matrix_data: @matrix_data,
        user: current_user,
        current_tenant: ActsAsTenant.current_tenant,
        tenants: current_user_tenants
      )
    else
      render Views::Assessments::ShowView.new(
        assignment: @assignment,
        framework: @framework,
        matrix_data: @matrix_data,
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
      context: assessment_context
    ), layout: false
  end

  # GET /assessments/:id/scoring
  def scoring
    authorize @assignment, :scoring?
    load_assessment_data
    render Views::Assessments::ScoringPanelFrameView.new(
      matrix_data: @matrix_data
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

    # First try own assignment
    @assignment = PersonFrameworkAssignment.for_person(current_person.id)
      .find_by(framework_id: params.expect(:id))

    unless @assignment
      # Try direct report's assignment (manager view)
      @assignment = find_report_assignment(params.expect(:id))
    end

    unless @assignment
      redirect_to assessments_path, alert: "Assessment not found."
      return
    end

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

  # Returns the assessment context based on the viewer's relationship.
  #
  # @return [Symbol] :self, :manager, or :alignment
  def assessment_context
    manager_viewing? ? :manager : :self
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
      categories: categories
    ).build
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

  # Finds a direct report's assignment for the given framework.
  #
  # @param framework_id [String]
  # @return [PersonFrameworkAssignment, nil]
  def find_report_assignment(framework_id)
    report_ids = current_person.direct_reports.pluck(:id)
    return nil if report_ids.empty?

    PersonFrameworkAssignment.where(person_id: report_ids, framework_id: framework_id).first
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end

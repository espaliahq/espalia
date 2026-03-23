# frozen_string_literal: true

# Self-assessment UI for the current user's framework assignments.
#
# The assessment ID in URLs is the framework_id — an assessment is a
# projection derived from the PersonDevelopment event stream, not a
# separate entity.
#
class AssessmentsController < ApplicationController
  before_action :set_person
  before_action :set_assignment, only: [ :show, :matrix ]

  # GET /assessments
  def index
    @assignments = PersonFrameworkAssignment.for_person(@person.id)
      .includes(:framework, :role, :level)
    render Views::Assessments::IndexView.new(
      assignments: @assignments,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /assessments/:id
  def show
    load_assessment_data
    render Views::Assessments::ShowView.new(
      assignment: @assignment,
      framework: @framework,
      matrix_data: @matrix_data,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /assessments/:id/matrix
  def matrix
    load_assessment_data
    render Views::Assessments::MatrixFrameView.new(
      assignment: @assignment,
      framework: @framework,
      matrix_data: @matrix_data
    ), layout: false
  end

  private

  def set_person
    tenant = ActsAsTenant.current_tenant
    tenant_user = ActsAsTenant.without_tenant do
      current_user.tenant_users.find_by(tenant: tenant)
    end
    @person = tenant_user&.person

    unless @person
      redirect_to root_path, alert: "No person profile linked to your account."
    end
  end

  def set_assignment
    @assignment = PersonFrameworkAssignment.for_person(@person.id)
      .find_by!(framework_id: params.expect(:id))
    @framework = FrameworkState::Framework.find_by!(framework_id: @assignment.framework_id)
  rescue ActiveRecord::RecordNotFound
    redirect_to assessments_path, alert: "Assessment not found."
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
      person_id: @person.id,
      categories: categories
    ).build
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end

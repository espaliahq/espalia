# frozen_string_literal: true

# Admin UI for managing assessment cycles within a tenant.
#
# Exposes index / show / new / create / close actions. Enrollment lives on
# a nested resource in {AssessmentCycles::EnrollmentsController}.
#
# Cycle define / close dispatches through {AssessmentCycles::CommandHandler},
# which publishes events that the {AssessmentCycles::Projections::CurrentState}
# projection materialises into the `assessment_cycles` read model.
#
class AssessmentCyclesController < ApplicationController
  before_action :set_cycle, only: [ :show, :close ]

  # GET /assessment_cycles
  def index
    authorize AssessmentCycle, :index?

    open_cycles = AssessmentCycle.open_cycles.includes(:framework).order(opened_at: :desc)
    closed_cycles = AssessmentCycle.closed_cycles.includes(:framework).order(opened_at: :desc)

    cycle_ids = (open_cycles + closed_cycles).map(&:cycle_id)
    participant_counts = AssessmentCycleParticipant
      .where(cycle_id: cycle_ids)
      .group(:cycle_id, :status)
      .count

    render Views::AssessmentCycles::IndexView.new(
      open_cycles: open_cycles,
      closed_cycles: closed_cycles,
      participant_counts: participant_counts,
      can_define_new: frameworks_without_open_cycle.any?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /assessment_cycles/:id
  def show
    authorize @cycle

    @cycle.participants.includes(:person).load
    framework = FrameworkState::Framework.find_by(framework_id: @cycle.framework_id)

    render Views::AssessmentCycles::ShowView.new(
      cycle: @cycle,
      framework: framework,
      eligible_people: @cycle.eligible_people.to_a,
      is_admin: policy(@cycle).enroll?,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # GET /assessment_cycles/new
  def new
    authorize AssessmentCycle, :define?

    render Views::AssessmentCycles::NewView.new(
      frameworks: frameworks_without_open_cycle,
      cycle_types: AssessmentCycle::CYCLE_TYPES,
      user: current_user,
      current_tenant: ActsAsTenant.current_tenant,
      tenants: current_user_tenants
    )
  end

  # POST /assessment_cycles
  def create
    authorize AssessmentCycle, :define?

    framework = FrameworkState::Framework.find_by!(framework_id: cycle_params[:framework_id])

    unless framework.current_published_version.to_i >= 1
      redirect_to new_assessment_cycle_path, status: :see_other,
                  alert: "Framework \"#{framework.name}\" has no published version — publish it first."
      return
    end

    cycle_id = SecureRandom.uuid_v7
    ActiveRecord::Base.transaction do
      AssessmentCycles::CommandHandler.new.define_cycle(
        cycle_id,
        framework.framework_id,
        cycle_params[:name],
        cycle_params[:cycle_type],
        framework.current_published_version,
        defined_by: current_person&.id
      )
    end

    new_cycle = AssessmentCycle.find_by!(cycle_id: cycle_id)
    redirect_to assessment_cycle_path(new_cycle), notice: "Cycle defined."
  rescue ActiveRecord::RecordNotUnique
    redirect_to new_assessment_cycle_path, status: :see_other,
                alert: "An open cycle already exists for this framework. Close it first."
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    redirect_to new_assessment_cycle_path, status: :see_other, alert: e.message
  end

  # POST /assessment_cycles/:id/close
  def close
    authorize @cycle, :close?

    # Wrapped in a transaction so the projection write (cycle status flip)
    # and every LeftAssessmentCycle event on participant streams commit
    # atomically. Without this, a partial fan-out could leave the cycle
    # closed while some participants still show as active.
    ActiveRecord::Base.transaction do
      AssessmentCycles::CommandHandler.new.close_cycle(
        @cycle.cycle_id, closed_by: current_person&.id
      )
    end
    redirect_to assessment_cycle_path(@cycle), status: :see_other, notice: "Cycle closed."
  rescue RuntimeError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    redirect_to assessment_cycle_path(@cycle), status: :see_other, alert: e.message
  end

  private

  def set_cycle
    @cycle = AssessmentCycle.find(params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to assessment_cycles_path, alert: "Cycle not found."
  end

  def cycle_params
    params.expect(assessment_cycle: [ :framework_id, :name, :cycle_type ])
  end

  # @return [ActiveRecord::Relation<FrameworkState::Framework>]
  def frameworks_without_open_cycle
    open_ids = AssessmentCycle.open_cycles.pluck(:framework_id)
    FrameworkState::Framework
      .where.not(framework_id: open_ids)
      .order(:name)
  end

  def current_user_tenants
    ActsAsTenant.without_tenant { current_user.tenants.to_a }
  end
end

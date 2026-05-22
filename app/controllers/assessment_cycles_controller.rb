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
  before_action :set_cycle, only: [ :show, :close, :rename, :change_type, :set_planned_end ]

  # GET /assessment_cycles
  def index
    authorize AssessmentCycle, :index?

    open_cycles = AssessmentCycle.open_cycles.includes(:framework).order(opened_at: :desc)
    closed_cycles = AssessmentCycle.closed_cycles.includes(:framework).order(opened_at: :desc)

    cycle_ids = (open_cycles + closed_cycles).map(&:cycle_id)
    participant_counts = AssessmentCycleEnrollment
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

    # Eager-load people for the enrollment join used by `#participations`.
    @cycle.enrollments.includes(:person).load
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
        defined_by: current_person&.id,
        planned_end_at: cycle_params[:planned_end_at]
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

  # PATCH /assessment_cycles/:id/rename
  def rename
    authorize @cycle, :update?
    return reject_closed_edit if @cycle.closed?

    new_name = rename_params[:name].to_s.strip
    return redirect_back_with_alert("Name can't be blank.") if new_name.empty?

    AssessmentCycles::CommandHandler.new.rename_cycle(
      @cycle.cycle_id, new_name, updated_by: current_person&.id
    )
    @cycle.reload
    respond_with_edit_frame(:name)
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    redirect_back_with_alert(e.message)
  end

  # PATCH /assessment_cycles/:id/change_type
  def change_type
    authorize @cycle, :update?
    return reject_closed_edit if @cycle.closed?

    new_type = change_type_params[:cycle_type]
    AssessmentCycles::CommandHandler.new.change_cycle_type(
      @cycle.cycle_id, new_type, updated_by: current_person&.id
    )
    @cycle.reload
    respond_with_edit_frame(:cycle_type)
  rescue RuntimeError, ActiveRecord::RecordInvalid => e
    redirect_back_with_alert(e.message)
  end

  # PATCH /assessment_cycles/:id/set_planned_end
  #
  # Accepts a blank value to clear the previously-set date.
  def set_planned_end
    authorize @cycle, :update?
    return reject_closed_edit if @cycle.closed?

    raw = set_planned_end_params[:planned_end_at]
    AssessmentCycles::CommandHandler.new.set_cycle_planned_end(
      @cycle.cycle_id, raw.presence, updated_by: current_person&.id
    )
    @cycle.reload
    respond_with_edit_frame(:planned_end_at)
  rescue RuntimeError, ActiveRecord::RecordInvalid, Date::Error => e
    redirect_back_with_alert(e.message)
  end

  private

  def set_cycle
    @cycle = AssessmentCycle.find(params.expect(:id))
  rescue ActiveRecord::RecordNotFound
    redirect_to assessment_cycles_path, alert: "Cycle not found."
  end

  def cycle_params
    params.expect(assessment_cycle: [ :framework_id, :name, :cycle_type, :planned_end_at ])
  end

  def rename_params
    params.expect(assessment_cycle: [ :name ])
  end

  def change_type_params
    params.expect(assessment_cycle: [ :cycle_type ])
  end

  def set_planned_end_params
    params.expect(assessment_cycle: [ :planned_end_at ])
  end

  def reject_closed_edit
    redirect_to assessment_cycle_path(@cycle), status: :see_other,
                alert: "Closed cycles can't be edited."
  end

  def redirect_back_with_alert(message)
    redirect_to assessment_cycle_path(@cycle), status: :see_other, alert: message
  end

  # Renders the Turbo frame for the just-edited field. The frame body is
  # the post-edit display state — Turbo finds the matching `<turbo-frame>`
  # in the response and swaps it in place.
  def respond_with_edit_frame(field)
    render frame_view_for(field), layout: false
  end

  def frame_view_for(field)
    case field
    when :name
      Views::AssessmentCycles::CycleNameFrame.new(cycle: @cycle, is_admin: true)
    when :cycle_type
      Views::AssessmentCycles::CycleTypeFrame.new(cycle: @cycle, is_admin: true)
    when :planned_end_at
      Views::AssessmentCycles::CyclePlannedEndFrame.new(cycle: @cycle, is_admin: true)
    end
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

# frozen_string_literal: true

# Manages per-cycle person enrollment / unenrollment.
#
# POST creates an enrollment; DELETE withdraws a participant with an optional
# reason string (defaults to "manual"). Both actions dispatch through
# {AssessmentCycles::CommandHandler}, which publishes events that cascade
# through {AssessmentCycles::SyncHandlers::PersonEnrollmentSync} to the
# PersonDev stream synchronously.
#
# The dispatch is wrapped in an ActiveRecord transaction so that a failure
# in any downstream sync handler (e.g. PersonDev's `Person not yet assigned`
# guard when enrolling a person who isn't assigned to the framework) rolls
# back the projection write atomically. RES subscribers run synchronously
# but NOT inside an implicit DB transaction — the controller must provide one.
#
# RuntimeError rescue catches:
#   - Aggregate guards ("Person already enrolled", "Cycle is closed")
#   - The PersonDev "Person not yet assigned to a framework" error
#   - Any other domain violation surfaced from the PersonEnrollmentSync chain
#
class AssessmentCycles::EnrollmentsController < ApplicationController
  before_action :set_cycle

  # POST /assessment_cycles/:assessment_cycle_id/enrollments
  def create
    authorize @cycle, :enroll?

    person_id = enrollment_params[:person_id]

    role_id, level_id = assignment_role_level(person_id)

    ActiveRecord::Base.transaction do
      AssessmentCycles::CommandHandler.new.enroll(
        @cycle.cycle_id, person_id, enrolled_by: current_person&.id,
        role_id: role_id, level_id: level_id
      )
    end
    redirect_to assessment_cycle_path(@cycle), notice: "Person enrolled."
  rescue RuntimeError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    redirect_to assessment_cycle_path(@cycle), status: :see_other, alert: e.message
  end

  # POST /assessment_cycles/:assessment_cycle_id/enrollments/bulk
  #
  # Enqueues background enrollment of every person currently eligible for
  # this cycle (assigned to the framework and not yet an active
  # participant). Runs as a job because each enrollment replays the
  # person's PersonDevelopment stream and seeds carried-forward ratings —
  # a real cohort inline reliably times the request out (production
  # incident, Q3 2026 cycle).
  def bulk
    authorize @cycle, :enroll?

    eligible_count = @cycle.eligible_people.count
    if eligible_count.zero?
      flash[:alert] = "No eligible people to enroll."
    else
      AssessmentCycles::BulkEnrollmentJob.perform_later(@cycle, enrolled_by: current_person&.id)
      flash[:notice] = "Enrolling #{eligible_count} eligible #{'person'.pluralize(eligible_count)} " \
                       "in the background — refresh in a moment to see them appear."
    end

    redirect_to assessment_cycle_path(@cycle)
  end

  # DELETE /assessment_cycles/:assessment_cycle_id/enrollments/:id
  def destroy
    authorize @cycle, :unenroll?

    enrollment = @cycle.enrollments.find(params.expect(:id))
    reason = params[:reason].presence || "manual"

    ActiveRecord::Base.transaction do
      AssessmentCycles::CommandHandler.new.unenroll(
        @cycle.cycle_id,
        enrollment.person_id,
        reason,
        unenrolled_by: current_person&.id
      )
    end
    redirect_to assessment_cycle_path(@cycle), status: :see_other, notice: "Person unenrolled."
  rescue ActiveRecord::RecordNotFound
    # A stale page can post an enrollment id that a projection rebuild has
    # reissued or a concurrent unenroll removed — fail soft, not 500.
    redirect_to assessment_cycle_path(@cycle), status: :see_other,
                alert: "That participant is no longer enrolled."
  rescue RuntimeError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    redirect_to assessment_cycle_path(@cycle), status: :see_other, alert: e.message
  end

  private

  def set_cycle
    @cycle = AssessmentCycle.find(params.expect(:assessment_cycle_id))
  rescue ActiveRecord::RecordNotFound
    redirect_to assessment_cycles_path, alert: "Cycle not found."
  end

  def enrollment_params
    params.expect(enrollment: [ :person_id ])
  end

  # Resolves the person's current role/level on this cycle's framework, to
  # snapshot as the assessed role/level at enrollment. Returns [nil, nil] when
  # the person has no assignment (the downstream PersonEnrollmentSync guard
  # surfaces that as a domain error).
  #
  # @param person_id [String]
  # @return [Array(String, String)] [role_id, level_id]
  def assignment_role_level(person_id)
    assignment = PersonFrameworkAssignment.find_by(
      person_id: person_id, framework_id: @cycle.framework_id
    )
    [ assignment&.role_id, assignment&.level_id ]
  end
end

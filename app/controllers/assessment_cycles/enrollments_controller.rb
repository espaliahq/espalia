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

    ActiveRecord::Base.transaction do
      AssessmentCycles::CommandHandler.new.enroll(
        @cycle.cycle_id, person_id, enrolled_by: current_person&.id
      )
    end
    redirect_to assessment_cycle_path(@cycle), notice: "Person enrolled."
  rescue RuntimeError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    redirect_to assessment_cycle_path(@cycle), status: :see_other, alert: e.message
  end

  # POST /assessment_cycles/:assessment_cycle_id/enrollments/bulk
  #
  # Enrolls every person currently eligible for this cycle (assigned to the
  # framework and not yet an active participant). Each enrollment runs in
  # its own transaction so a domain failure on one person — e.g. a race
  # with another admin enrolling the same person — does not block the rest.
  def bulk
    authorize @cycle, :enroll?

    enrolled = 0
    skipped = 0
    command_handler = AssessmentCycles::CommandHandler.new

    @cycle.eligible_people.find_each do |person|
      ActiveRecord::Base.transaction do
        command_handler.enroll(
          @cycle.cycle_id, person.id, enrolled_by: current_person&.id
        )
      end
      enrolled += 1
    rescue RuntimeError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      skipped += 1
    end

    if enrolled.zero? && skipped.zero?
      flash[:alert] = "No eligible people to enroll."
    else
      message = "Enrolled #{enrolled} #{'person'.pluralize(enrolled)}."
      message += " Skipped #{skipped}." if skipped.positive?
      flash[enrolled.positive? ? :notice : :alert] = message
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
end

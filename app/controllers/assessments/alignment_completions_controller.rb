# frozen_string_literal: true

# Marks alignment complete for the current cycle of an assessment.
#
# After this lands, ALL ratings (including aligned values) are frozen for
# the cycle. Only the assessee's current direct manager can call this — see
# {AssessmentPolicy#complete_alignment?}.
#
# Completion is gated on FULL current-level aligned coverage: every
# capability with a cell at the assessed level must carry an agreed value
# before the record can be formalised. The manager can always record agreed
# values, so the gate can never deadlock — it forbids leaving cells
# implicit, not disagreement. Two layers: the read-model check here gives
# the friendly redirect + count, then the counted cells are forwarded into
# the aggregate (`required_cell_keys`), which re-runs the check atomically
# against the stream — the denominator (which capabilities have a cell at
# the assessed level) is framework structure the PersonDevelopment stream
# doesn't carry, so the edge supplies it and the aggregate enforces it.
# This controller is the sole completion entry point (no MCP tool exists for
# it); any future Operation/MCP tool must forward the same cell keys.
#
class Assessments::AlignmentCompletionsController < ApplicationController
  before_action :require_person
  before_action :set_assignment

  # POST /assessments/:assessment_id/alignment_completion
  def create
    authorize @assignment, :complete_alignment?

    cycle = @assignment.current_open_cycle
    unless cycle
      redirect_to assessment_path(@assignment), alert: "No open assessment cycle."
      return
    end

    coverage = aligned_coverage(cycle)
    if coverage[:total].positive? && !coverage[:aligned_complete]
      remaining = coverage[:total] - coverage[:aligned_rated]
      redirect_to assessment_path(@assignment),
        alert: "#{remaining} current-level #{'capability'.pluralize(remaining)} still " \
               "#{remaining == 1 ? 'needs' : 'need'} an agreed rating before alignment " \
               "can be marked complete."
      return
    end

    # Forward the counted cells so the aggregate re-runs the coverage check
    # atomically against the stream — a concurrent clear between the
    # read-model check above and this command landing can't slip a gap into
    # the completed record.
    PersonDevelopment::CommandHandler.new.complete_alignment(
      @assignment.person_id, @assignment.framework_id, cycle.cycle_id,
      completed_by_id: current_person.id,
      required_cell_keys: coverage[:current_level_cell_keys]
    )

    redirect_to assessment_path(@assignment),
      notice: "Alignment complete — all ratings for this cycle are now locked."
  rescue RuntimeError => e
    Rails.logger.error("[AlignmentCompletions] #{e.class}: #{e.message}")
    redirect_to assessment_path(@assignment),
      alert: "Could not mark alignment complete."
  end

  private

  # Current-level aligned coverage for the completion gate. A role with no
  # current-level cells never blocks (mirrors the hero's zero-cell unlock) —
  # there is nothing to align, so completion proceeds.
  #
  # @param cycle [AssessmentCycle]
  # @return [Hash] see {Assessments::LevelCoverage#call}
  def aligned_coverage(cycle)
    Assessments::LevelCoverage.new(
      person_id: @assignment.person_id,
      framework_id: @assignment.framework_id,
      cycle_id: cycle.cycle_id
    ).call(include_aligned: true)
  end

  def require_person
    head :forbidden unless current_person
  end

  def set_assignment
    return unless current_person

    @assignment = PersonFrameworkAssignment.find(params.expect(:assessment_id))
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  def user_not_authorized(_exception = nil)
    head :forbidden
  end
end

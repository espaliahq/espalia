# frozen_string_literal: true

# Records an aligned frequency for one capability × level — the
# manager + assessee agreement on what the rating should be once
# alignment has started. Same input shape as
# {Operations::Assessments::RateSelf} and
# {Operations::Assessments::RateAsManager}, with two differences:
#
# - No toggle semantics. Alignment is a single dispatch via
#   `PersonDevelopment::CommandHandler#align_assessment`; the command
#   handles re-alignment in place (the aligned value just overwrites).
#   This matches the web AlignmentRatingsController.
# - The cycle must be in `aligning` status — `create_alignment_rating?`
#   enforces this via the participant_status check.
#
# Alignment is against the home role, so the cell must be one the record
# reads (ADR-22); `as_role_id` is accepted for the shared input shape and
# the same cell check.
#
# Write — :mcp_client approval, same reasoning as the other two
# rating tools.
class Operations::Assessments::Align < Operations::Base
  include Operations::Assessments::RatingCell

  description "Record the aligned (agreed) frequency for one capability × level of the assessee's own role."
  category :write
  approval :mcp_client

  parameter :assignment_id,        String, required: true
  parameter :capability_stable_id, String, required: true
  parameter :level_ordinal,        Integer, required: true
  parameter :frequency, String, required: true,
                                allowed: %w[none some occasional consistent]
  parameter :comment, String
  # The role whose cells the pair is reading; blank = the home role.
  parameter :as_role_id, String

  def policy_check
    authorize assignment, :create_alignment_rating?
    rating_lens
    refuse_outside_home_role!
  end

  # @return [Hash] same shape as {Operations::Assessments::RateSelf#perform} —
  #   `{ framework_id, capability_stable_id, level_ordinal, cycle_id, frequency }`.
  #   Unlike the other two rating ops, `frequency` is always the value the
  #   caller submitted: alignment has no untoggle (re-aligning overwrites).
  def perform
    cycle = assignment.current_open_cycle
    raise Operations::Base::ParameterError, "no open assessment cycle" if cycle.nil?

    PersonDevelopment::CommandHandler.new.align_assessment(
      assignment.person_id, assignment.framework_id, params[:capability_stable_id],
      level_ordinal: params[:level_ordinal], aligned_frequency: params[:frequency],
      cycle_id: cycle.cycle_id, comment: params[:comment], aligned_by_id: context.person&.id
    )

    {
      framework_id: assignment.framework_id,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal],
      cycle_id: cycle.cycle_id,
      frequency: aligned_frequency(cycle.cycle_id)
    }
  end

  private

  def aligned_frequency(cycle_id)
    AssessmentLevelRating.find_by(
      cycle_id: cycle_id, person_id: assignment.person_id,
      framework_id: assignment.framework_id,
      capability_stable_id: params[:capability_stable_id],
      level_ordinal: params[:level_ordinal]
    )&.aligned_frequency
  end

  def assignment
    @assignment ||= PersonFrameworkAssignment.find(params[:assignment_id])
  end
end

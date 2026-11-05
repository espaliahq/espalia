# frozen_string_literal: true

# Every cycle one person enrolled in on one framework — open, closed or
# withdrawn from — with what the read models know of when each milestone
# happened. Newest cycle first. The stamps are the latest occurrence (a
# re-open clears `aligned_at`); the event stream holds the rest.
#
# @example
#   Assessments::CycleHistory.new(assignment: assignment).call.first.cycle.name
class Assessments::CycleHistory
  Entry = Data.define(:cycle, :enrollment, :progress, :role_alignments)

  # @param assignment [PersonFrameworkAssignment]
  def initialize(assignment:)
    @assignment = assignment
  end

  # @return [Array<Entry>]
  def call
    cycles = AssessmentCycle.where(framework_id: @assignment.framework_id).index_by(&:cycle_id)
    enrollments = AssessmentCycleEnrollment.for_person(@assignment.person_id).where(cycle_id: cycles.keys).to_a
    return [] if enrollments.empty?

    cycle_ids = enrollments.map(&:cycle_id)
    progress = AssessmentCycleProgress.where(cycle_id: cycle_ids, person_id: @assignment.person_id).index_by(&:cycle_id)
    alignments = AssessmentCycleRoleAlignment.where(cycle_id: cycle_ids, person_id: @assignment.person_id)
      .order(home: :desc, alignment_started_at: :asc).group_by(&:cycle_id)

    enrollments
      .map { |e| Entry.new(cycle: cycles[e.cycle_id], enrollment: e, progress: progress[e.cycle_id], role_alignments: alignments.fetch(e.cycle_id, [])) }
      .sort_by { |entry| [ -entry.cycle.opened_at.to_f, entry.cycle.cycle_id ] }
  end
end

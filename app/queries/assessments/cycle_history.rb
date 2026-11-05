# frozen_string_literal: true

# Every cycle one person enrolled in on one framework — open, closed or
# withdrawn from — with its {Assessments::Lifecycle} and role alignment rows
# (home first). Newest cycle first.
#
# @example
#   Assessments::CycleHistory.new(assignment: assignment).call.first.cycle.name
class Assessments::CycleHistory
  Entry = Data.define(:cycle, :enrollment, :progress, :lifecycle, :role_alignments)

  # @param assignment [PersonFrameworkAssignment]
  def initialize(assignment:)
    @assignment = assignment
  end

  # @return [Array<Entry>]
  def call
    enrollments = AssessmentCycleEnrollment.for_person(@assignment.person_id)
      .joins(:cycle).where(assessment_cycles: { framework_id: @assignment.framework_id })
      .order("assessment_cycles.opened_at DESC, assessment_cycles.cycle_id DESC")
      .includes(:cycle).to_a
    return [] if enrollments.empty?

    cycle_ids = enrollments.map(&:cycle_id)
    progress = AssessmentCycleProgress.where(cycle_id: cycle_ids, person_id: @assignment.person_id).index_by(&:cycle_id)
    alignments = AssessmentCycleRoleAlignment.where(cycle_id: cycle_ids, person_id: @assignment.person_id)
      .order(home: :desc, alignment_started_at: :asc).group_by(&:cycle_id)

    enrollments.map do |enrollment|
      prog = progress[enrollment.cycle_id]
      Entry.new(cycle: enrollment.cycle, enrollment: enrollment, progress: prog,
                lifecycle: Assessments::Lifecycle.from(enrollment: enrollment, progress: prog),
                role_alignments: alignments.fetch(enrollment.cycle_id, []))
    end
  end
end

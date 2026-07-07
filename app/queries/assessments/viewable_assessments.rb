# frozen_string_literal: true

# Bulk "which of these people's assessments can the viewer open?" resolver.
#
# Mirrors {AssessmentPolicy#show?} — tenant/global admin, the person
# themselves, the live manager chain ({Person#all_reports} is the downward
# walk of the same chart {Person#managed_by?} walks upward), the recorded
# reporting manager, and active rating delegates — but answers it for a whole
# participant list in a fixed number of queries instead of one policy walk per
# row. Used by list surfaces (cycle participants, cohort drill-down) to decide
# which names link to `assessment_path`.
#
# Parity with the per-record policy is pinned by
# test/queries/assessments/viewable_assessments_test.rb — change both together.
class Assessments::ViewableAssessments
  # @param viewer [AuthorizationContext]
  # @param framework_id [String]
  # @param person_ids [Array<String>]
  def initialize(viewer:, framework_id:, person_ids:)
    @viewer = viewer
    @framework_id = framework_id
    @person_ids = person_ids.uniq
  end

  # @return [Hash{String => PersonFrameworkAssignment}] person_id → assignment,
  #   only for people whose assessment the viewer may open AND who still hold
  #   an assignment on the framework (no assignment → nothing to link to)
  def call
    return {} if @person_ids.empty?

    assignments = PersonFrameworkAssignment
      .where(framework_id: @framework_id, person_id: @person_ids)
      .index_by(&:person_id)
    assignments.slice(*viewable_person_ids(assignments.keys))
  end

  private

  def viewable_person_ids(candidate_ids)
    return candidate_ids if @viewer.tenant_admin?

    person = @viewer.person
    return [] unless person

    ids = Set.new
    ids << person.id
    ids.merge(person.all_reports.pluck(:id))
    ids.merge(recorded_report_ids)
    ids.merge(active_delegation_ids)
    candidate_ids.select { |id| ids.include?(id) }
  end

  # People whose recorded reporting manager is the viewer — covers the case
  # where the recorded manager is no longer the live-chart manager (the
  # recorded fact stays authoritative for view/rating until the next sync).
  def recorded_report_ids
    RecordedReportingManager
      .for_framework(@framework_id)
      .where(manager_id: @viewer.person.id)
      .pluck(:person_id)
  end

  def active_delegation_ids
    ManagerAssessmentDelegation.active
      .for_framework(@framework_id)
      .for_delegate(@viewer.person.id)
      .pluck(:person_id)
  end
end

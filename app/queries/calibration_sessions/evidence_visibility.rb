# frozen_string_literal: true

# Which of a calibration session's population the VIEWER may read evidence
# for, per {EvidencePolicy#view_assessment?}.
#
# The session surfaces used to assume this rather than check it: the design
# says the facilitator is an ancestor of the whole population, so the
# underlying assessment reads are already authorized. That assumption does
# not hold. `Operations::CalibrationSessions::ScopeChecks` deliberately
# exempts anyone a PARTICIPANT is attributed — via an active rating
# delegation, or a recorded reporting manager that diverges from the live
# chain — and those people sit outside the facilitator's own subtree by
# construction. So a session can legitimately contain someone whose
# evidence `/assessments` would refuse the facilitator, and the wall and
# person card would render their peer feedback verbatim.
#
# Ratings are deliberately NOT filtered here: the grid is the session's
# whole point and the population is a curated, frozen decision. It is the
# free-text feedback — written by peers under a narrower visibility
# disclosure — that needs the entitlement check.
#
# Batched: one subtree query plus one delegation query, never a policy call
# per person.
class CalibrationSessions::EvidenceVisibility
  # @param viewer [Person, nil] the acting person (nil ⇒ nothing visible)
  # @param framework_id [String]
  # @param candidate_ids [Array<String>] population person_ids
  # @param admin [Boolean] tenant/global admin sees the whole tenant
  def initialize(viewer:, framework_id:, candidate_ids:, admin: false)
    @viewer = viewer
    @framework_id = framework_id
    @candidate_ids = Array(candidate_ids).uniq
    @admin = admin
  end

  # @return [Array<String>] the subset whose evidence the viewer may read
  def person_ids
    @person_ids ||= begin
      return [] if @viewer.nil? && !@admin
      return @candidate_ids if @admin || @candidate_ids.empty?

      (subtree_ids + delegated_ids + [ @viewer.id ]).uniq & @candidate_ids
    end
  end

  private

  def subtree_ids
    @viewer.all_reports.where(id: @candidate_ids).pluck(:id)
  end

  # A viewer holding an active rating delegation reads that person's
  # evidence exactly as their manager would (EvidencePolicy's rule).
  def delegated_ids
    ManagerAssessmentDelegation.active
      .for_framework(@framework_id)
      .for_delegate(@viewer.id)
      .where(person_id: @candidate_ids)
      .pluck(:person_id)
  end
end

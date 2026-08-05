# frozen_string_literal: true

# Which of a calibration session's population the VIEWER is entitled to read
# an assessment for — the same set `EvidencePolicy#view_assessment?` and
# `AssessmentPolicy#show?` admit (both are: admin ∥ self ∥ manager chain ∥
# active delegate).
#
# The session surfaces used to assume this rather than check it: the design
# says the facilitator is an ancestor of the whole population, so the
# underlying assessment reads are already authorized. That assumption does
# not hold. `Operations::CalibrationSessions::ScopeChecks` deliberately
# exempts anyone a PARTICIPANT is attributed — via an active rating
# delegation, or a recorded reporting manager that diverges from the live
# chain — and those people sit outside the facilitator's own subtree by
# construction. So a session can legitimately contain someone whose
# assessment `/assessments` would refuse the facilitator.
#
# **What the gate covers is the ASSESSEE's own contributions**: their peer
# and self feedback, and their self-rating. Those are the person's private
# inputs, written under a visibility disclosure naming their managers and
# admins — not "a room of EMs one of their peers' managers happens to run".
#
# **Manager ratings are deliberately NOT gated.** They belong to a rater who
# is in the room and is there to defend them — calibrating those raters is
# the session's entire purpose, and the population is a curated, frozen
# decision the facilitator made. Withholding the rating would empty the grid
# of exactly the cells the delegation exemption exists to include.
#
# Batched: one subtree query plus one delegation query, never a policy call
# per person.
class CalibrationSessions::AssesseeVisibility
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
    @person_ids ||= resolve
  end

  private

  # Split out so every branch memoizes — a `return` inside the `||=`'s block
  # returns from the method, leaving the early exits recomputed on each call.
  def resolve
    return [] if @viewer.nil? && !@admin
    return @candidate_ids if @admin || @candidate_ids.empty?

    (subtree_ids + delegated_ids + [ @viewer.id ]).uniq & @candidate_ids
  end

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

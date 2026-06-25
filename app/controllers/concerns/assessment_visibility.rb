# frozen_string_literal: true

# Shared "who can see this assessment's evidence/ratings" rule for the
# controllers that render a person's assessment surface — the page
# (`AssessmentsController`), the activity-feed frame
# (`Assessments::ActivityController`), and the evidence frames
# (`Assessments::EvidenceController`).
#
# Kept in ONE place so the rule can't drift between controllers. It did: the
# original delegation work updated only `AssessmentsController#viewer_sees_all_evidence?`,
# leaving the activity feed and evidence-list re-renders blind to delegates, so
# a delegate saw "No activity yet" and an empty evidence list.
#
# Requires `@assignment` (a `PersonFrameworkAssignment`) to be set.
module AssessmentVisibility
  extend ActiveSupport::Concern

  private

  # Whether the viewer may see ALL evidence (not just their own) and the
  # manager-perspective activity entries: the assessee, anyone in their manager
  # chain, a tenant admin, OR an active manager-rating delegate.
  #
  # @return [Boolean]
  def viewer_sees_all_evidence?
    return false unless current_person
    return true if current_user&.global_admin? || current_tenant_user&.admin?
    return true if @assignment.person_id == current_person.id
    return true if active_rating_delegate?

    assessment_assessee&.managed_by?(current_person) || false
  end

  # Whether the viewer may relink evidence they did NOT author — the assessee,
  # anyone in their manager chain, or an active rating delegate (a delegate is
  # treated like a manager for everything except starting/editing alignment).
  # Authors always get relink on their own items via `Evidence::List#can_relink?`.
  #
  # @return [Boolean]
  def viewer_can_relink_others_evidence?
    return false unless current_person
    return true if @assignment.person_id == current_person.id
    return true if active_rating_delegate?

    assessment_assessee&.managed_by?(current_person) || false
  end

  # Whether the viewer is the manager-side party rather than the assessee —
  # i.e. anyone who is not the person being assessed (the reporting manager,
  # a manager-chain ancestor, an active rating delegate, or a tenant admin
  # viewing). Drives the split-chip / hero ordering, where the viewer's own
  # perspective leads. Requires `current_person` (callers run after
  # `require_person`).
  #
  # @return [Boolean]
  def viewer_is_manager?
    @assignment.person_id != current_person&.id
  end

  # Whether the viewer holds an active manager-rating delegation for this
  # assessment. Memoised — one lookup per request.
  #
  # @return [Boolean]
  def active_rating_delegate?
    return @active_rating_delegate if defined?(@active_rating_delegate)
    return (@active_rating_delegate = false) unless current_person

    @active_rating_delegate = ManagerAssessmentDelegation.active_delegate?(
      person_id: @assignment.person_id,
      framework_id: @assignment.framework_id,
      delegate_person_id: current_person.id
    )
  end

  # The assessed person. Memoised.
  #
  # @return [Person, nil]
  def assessment_assessee
    @assessment_assessee ||= Person.find_by(id: @assignment.person_id)
  end
end

# frozen_string_literal: true

# Authorization policy for {EvidenceItem}.
#
# The record is a {PersonFrameworkAssignment} for create/index actions
# (we authorize at the assessment level — there is no evidence to inspect
# yet) and an {EvidenceItem} for actions on an existing record.
#
# Permission model (V1):
# - View: assessee + everyone in their manager hierarchy + tenant admin.
# - Record self evidence: the assessee on themselves.
# - Record manager evidence: anyone in the assessee's manager hierarchy.
# - Record peer evidence: any tenant member with a Person record.
# - Withdraw: original author + tenant admin.
# - Relink: original author + the assessee + anyone in their manager hierarchy
#   + an active manager-rating delegate.
#
# Evidence is NOT frozen during alignment — these checks are independent
# of `participant.status`.
#
class EvidencePolicy < ApplicationPolicy
  # @return [Boolean]
  def index? = view_assessment?

  # @return [Boolean]
  def show? = view_evidence?

  # Whether the viewer can record any evidence at all on this assessment.
  # The specific source ("self" / "manager" / "peer") is inferred at the
  # controller layer based on the viewer's relationship to the assessee.
  #
  # @return [Boolean]
  def create?
    return false unless person.present?

    owns_assessment? || in_assessee_manager_chain? || tenant_member?
  end

  # @return [Boolean]
  def withdraw?
    return false unless person.present?
    return false unless record.is_a?(EvidenceItem)
    return true if tenant_admin?

    record.author_id == person.id
  end

  # Editing the user-correctable content of an evidence item is strictly
  # author-only — narrower than `withdraw?`. Admins do NOT get an override
  # because editing reframes the author's words, which is a domain judgement
  # admins lack (matches `relink?`'s reasoning). Withdrawn items are not
  # editable; relinks remain available for moving evidence around.
  #
  # @return [Boolean]
  def update?
    return false unless person.present?
    return false unless record.is_a?(EvidenceItem)
    return false if record.withdrawn?

    record.author_id == person.id
  end

  # Note the asymmetry with `withdraw?`: tenant admins can withdraw (treat
  # as a content-neutral cleanup) but cannot relink — relinking reattributes
  # evidence to a different capability/level, which is a domain judgement
  # that requires familiarity with the assessee's work that admins generally
  # lack. The author or someone in the assessee's chain should make that call.
  #
  # @return [Boolean]
  def relink?
    return false unless person.present?
    return false unless record.is_a?(EvidenceItem)
    return true if record.author_id == person.id
    return true if record.person_id == person.id
    return true if active_rating_delegate?

    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end

  private

  # An active manager-rating delegate is treated like a manager for evidence
  # relinking (a delegate has full manager parity except starting/editing
  # alignment). Mirrors {AssessmentPolicy#active_rating_delegate?}.
  def active_rating_delegate?
    return false unless person.present?
    return false unless record.respond_to?(:framework_id) && record.framework_id

    ManagerAssessmentDelegation.active_delegate?(
      person_id: record.person_id,
      framework_id: record.framework_id,
      delegate_person_id: person.id
    )
  end

  # Whether the viewer can see evidence on the assessment as a whole.
  # The record may be a {PersonFrameworkAssignment} (collection-level) or
  # an {EvidenceItem} (member-level) — both expose `person_id`, so the
  # check resolves uniformly.
  def view_assessment?
    return false unless person.present?
    return true if tenant_admin?
    return true if record.person_id == person.id

    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end

  alias_method :view_evidence?, :view_assessment?

  def owns_assessment?
    person.present? && record.person_id == person.id
  end

  def in_assessee_manager_chain?
    return false unless person.present?

    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end
end

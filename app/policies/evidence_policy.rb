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
# - Relink: original author + the assessee + anyone in their manager hierarchy.
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

  # @return [Boolean]
  def relink?
    return false unless person.present?
    return false unless record.is_a?(EvidenceItem)
    return true if record.author_id == person.id
    return true if record.person_id == person.id

    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end

  private

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

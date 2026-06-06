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
# - Add link / remove link: original author + the assessee + anyone in
#   their manager hierarchy + an active manager-rating delegate. Managing
#   which capability × level an item is attached to is the same "where does
#   this evidence belong?" domain judgement the (now retired) relink action
#   gated — admins are excluded for the same reason (they lack the
#   familiarity with the assessee's work to make that call), while a
#   delegate (trusted to rate in the manager's place) is included.
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
  # admins lack (matches the link-management reasoning). Withdrawn items are
  # not editable; add/remove link remain available for managing where
  # evidence appears.
  #
  # @return [Boolean]
  def update?
    return false unless person.present?
    return false unless record.is_a?(EvidenceItem)
    return false if record.withdrawn?

    record.author_id == person.id
  end

  # Whether the viewer may attach this evidence to an additional
  # capability × level. See `can_manage_links?` for the actor model and
  # the asymmetry with `withdraw?` (admins can withdraw but not decide
  # where evidence belongs).
  #
  # @return [Boolean]
  def add_link? = can_manage_links?

  # Whether the viewer may remove one of this evidence's capability × level
  # links. Same actor model as `add_link?`. (The last-link invariant — an
  # active item must keep ≥1 link — is enforced in the aggregate, not here.)
  #
  # @return [Boolean]
  def remove_link? = can_manage_links?

  private

  # Author + the assessee + anyone in their manager hierarchy + an active
  # manager-rating delegate. Tenant admins are intentionally excluded:
  # deciding which capability/level a piece of evidence demonstrates is a
  # domain judgement that requires familiarity with the assessee's work —
  # which is exactly why a delegate (who the reporting manager trusted to
  # rate in their place) IS included.
  def can_manage_links?
    return false unless person.present?
    return false unless record.is_a?(EvidenceItem)
    return true if record.author_id == person.id
    return true if record.person_id == person.id
    return true if active_rating_delegate?

    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end

  # Whether the viewer can see evidence on the assessment as a whole.
  # The record may be a {PersonFrameworkAssignment} (collection-level) or
  # an {EvidenceItem} (member-level) — both expose `person_id` and
  # `framework_id`, so the check resolves uniformly. Active rating
  # delegates see the assessee's evidence like a manager would.
  def view_assessment?
    return false unless person.present?
    return true if tenant_admin?
    return true if record.person_id == person.id
    return true if active_rating_delegate?

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

  # Whether the viewer holds an active manager-rating delegation for the
  # assessee on this framework. Mirrors {AssessmentPolicy#active_rating_delegate?}
  # so a delegate gets the same evidence reach (view + manage links) the
  # reporting manager has. The record exposes `person_id` + `framework_id`
  # whether it is an {EvidenceItem} or a {PersonFrameworkAssignment}.
  def active_rating_delegate?
    return false unless person.present?
    return false unless record.respond_to?(:framework_id) && record.framework_id

    ManagerAssessmentDelegation.active_delegate?(
      person_id: record.person_id,
      framework_id: record.framework_id,
      delegate_person_id: person.id
    )
  end
end

# frozen_string_literal: true

# Authorization policy for {PersonDevelopmentComment}.
#
# Permission model:
# - Index/show on the assessment: assessee + everyone in their manager
#   hierarchy + tenant admin.
# - Post (create): same as view — only viewers of the assessment may
#   comment on it. Commenting on someone else's development without
#   visibility into the assessment is not a valid scenario in the
#   domain; conversation context follows the assessment's audience.
# - Update: original author only. Admins do NOT override — editing
#   re-writes the author's words, which is a domain judgement admins
#   lack (mirrors {EvidencePolicy#update?}).
# - Destroy: original author + tenant admin (cleanup affordance for
#   abuse/cleanup, mirrors {EvidencePolicy#withdraw?}).
#
# Comments are NOT frozen during alignment — these checks are
# independent of `participant.status`.
#
# The record is a {PersonFrameworkAssignment} for index/create actions
# (we authorize at the assessment level — no comment yet) and a
# {PersonDevelopmentComment} for actions on an existing comment.
#
class PersonDevelopmentCommentPolicy < ApplicationPolicy
  # @return [Boolean]
  def index? = view_assessment?

  # @return [Boolean]
  def show? = view_assessment?

  # @return [Boolean]
  def create? = view_assessment?

  # @return [Boolean]
  def update?
    return false unless person.present?
    return false unless record.is_a?(PersonDevelopmentComment)
    return false if record.deleted?

    record.author_id == person.id
  end

  # @return [Boolean]
  def destroy?
    return false unless person.present?
    return false unless record.is_a?(PersonDevelopmentComment)
    # Reject redundant deletes on already-deleted comments. The aggregate
    # would raise CommandError anyway, but rejecting at the policy keeps
    # the controller's flash messaging consistent with `update?`, which
    # mirrors the same guard.
    return false if record.deleted?
    return true if tenant_admin?

    record.author_id == person.id
  end

  private

  # The record may be a {PersonFrameworkAssignment} (collection-level) or
  # a {PersonDevelopmentComment} (member-level). Both expose `person_id`.
  def view_assessment?
    return false unless person.present?
    return true if tenant_admin?
    return true if record.person_id == person.id

    assessee = Person.find_by(id: record.person_id)
    assessee&.managed_by?(person) || false
  end
end

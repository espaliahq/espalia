# frozen_string_literal: true

# Resolves framework collaborator permissions for the current person.
#
# A person can hold multiple collaborator roles on the same framework.
# Permissions are the union of all held roles (additive, never subtractive).
#
# Include in FrameworkPolicy to activate collaborator-based authorization.
#
module FrameworkCollaboratorPermissions
  extend ActiveSupport::Concern

  private

  # This person's collaborator roles on this framework, loaded ONCE. Every
  # predicate below used to be its own `EXISTS` query, and one edit-mode render
  # asks several of them; the value object answers them from the roles it
  # already holds (#383).
  #
  # @return [Frameworks::CollaboratorRoles]
  def collaborator_roles
    @collaborator_roles ||= Frameworks::CollaboratorRoles.load(
      framework_id: record.framework_id, person_id: person&.id
    )
  end

  # @return [Boolean]
  def has_any_collaborator_role?
    collaborator_roles.any?
  end

  # @return [Boolean]
  def can_suggest?
    collaborator_roles.can_suggest?
  end

  # @return [Boolean]
  def can_publish?
    collaborator_roles.can_publish?
  end

  # @return [Boolean]
  def can_manage_collaborators?
    collaborator_roles.owner?
  end

  # Whether the person can approve a suggestion at the given review tier.
  #
  # @param tier [Integer] 1, 2, or 3
  # @return [Boolean]
  def can_approve_tier?(tier)
    case tier
    when 1 then collaborator_roles.can_edit?
    when 2, 3 then collaborator_roles.can_approve_content?
    else false
    end
  end
end

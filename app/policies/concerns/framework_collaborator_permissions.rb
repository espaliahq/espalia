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

  # All collaborator records for this person on this framework.
  #
  # @return [ActiveRecord::Relation<FrameworkState::Collaborator>]
  def collaborator_roles
    @collaborator_roles ||= FrameworkState::Collaborator
      .for_framework(record.framework_id)
      .for_person(person.id)
  end

  # @return [Boolean]
  def has_any_collaborator_role?
    collaborator_roles.exists?
  end

  # @return [Boolean]
  def can_suggest?
    collaborator_roles.with_suggest_rights.exists?
  end

  # @return [Boolean]
  def can_publish?
    collaborator_roles.with_publish_rights.exists?
  end

  # @return [Boolean]
  def can_manage_collaborators?
    collaborator_roles.where(role: "owner").exists?
  end

  # Whether the person can approve a suggestion at the given review tier.
  #
  # @param tier [Integer] 1, 2, or 3
  # @return [Boolean]
  def can_approve_tier?(tier)
    case tier
    when 1
      collaborator_roles.with_edit_rights.exists?
    when 2
      collaborator_roles.where(role: %w[owner editor capability_category_lead capability_lead]).exists?
    when 3
      collaborator_roles.where(role: %w[owner editor capability_category_lead capability_lead]).exists?
    else
      false
    end
  end
end

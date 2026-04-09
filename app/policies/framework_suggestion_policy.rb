# frozen_string_literal: true

# Authorization policy for framework suggested edits.
#
# Tier-based approval:
# - Tier 1 (RoleIllustration): any collaborator with edit rights
# - Tier 2 (Capability/Category/Role/RoleFamily/Level): owner, editor, capability_category_lead, capability_lead
# - Tier 3 (BehaviouralExpectation): owner, editor, capability_category_lead, capability_lead
#
# Tenant admins can approve any tier. Authors can amend or withdraw their
# own pending suggestions only.
#
class FrameworkSuggestionPolicy < ApplicationPolicy
  include FrameworkCollaboratorPermissions

  # @return [Boolean]
  def index? = tenant_member?

  # @return [Boolean]
  def show? = tenant_member?

  # @return [Boolean]
  def approve?
    return true if tenant_admin?
    return false unless person.present?
    can_approve_tier?(review_tier)
  end

  # @return [Boolean]
  def reject? = approve?

  # @return [Boolean]
  def amend? = pending? && author?

  # @return [Boolean]
  def withdraw? = pending? && author?

  private

  # Maps the suggestion's target entity type to its review tier (1, 2, or 3).
  #
  # @return [Integer]
  def review_tier
    case record.target_entity_type
    when "role_illustration" then 1
    when "behavioural_expectation" then 3
    else 2
    end
  end

  # @return [Boolean]
  def author?
    return false unless user.present?
    record.author_id == user.id.to_s
  end

  # @return [Boolean]
  def pending?
    record.status == "pending"
  end
end

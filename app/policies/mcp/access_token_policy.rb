# frozen_string_literal: true

# Authorization for the user-facing "Connected MCP clients" settings
# page. Listing requires a signed-in user; revoking requires ownership
# of the token (resource_owner_id == user.id). The controller already
# scopes queries to current_user.id; this policy is the second line of
# defense.
class Mcp::AccessTokenPolicy < ApplicationPolicy
  def index? = user.present?

  def destroy?
    user.present? && record.respond_to?(:resource_owner_id) && record.resource_owner_id == user.id
  end
end

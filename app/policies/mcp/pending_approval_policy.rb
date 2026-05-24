# frozen_string_literal: true

# Authorization for the in-app MCP approval review flow. An approval URL
# is the bearer secret — only the user who initiated the MCP tool call
# may view, approve, or reject the pending operation. The controller
# also scopes lookup to current_user.id; this policy is the second line
# of defense (and the canonical permission boundary).
class Mcp::PendingApprovalPolicy < ApplicationPolicy
  def show?    = owner?
  def approve? = owner?
  def reject?  = owner?

  private

  def owner?
    user.present? && record.user_id == user.id
  end
end

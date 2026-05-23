# frozen_string_literal: true

# In-app review UI for MCP operations that require explicit user
# confirmation (publish framework version, close cycle, grant
# collaborator, etc — anything declared `approval :in_app`). The MCP
# client surfaces a URL routed here; the user reviews the proposed
# operation + arguments and clicks Approve or Reject.
#
# Approve dispatches the deferred Operation under a freshly rebuilt
# AuthorizationContext (Pundit policies still apply — the user's role
# may have changed since the MCP call). Reject simply marks the row.
class Mcp::ApprovalsController < ApplicationController
  before_action :load_approval

  # GET /mcp/approvals/:id
  def show
    render Views::Mcp::Approvals::ShowView.new(approval: @approval)
  end

  # POST /mcp/approvals/:id/approve
  def approve
    return redirect_to mcp_approval_path(@approval), alert: stale_alert unless @approval.resolvable?

    Mcp::PendingApproval.transaction do
      result = @approval.operation.call(context: pundit_user, params: @approval.arguments)
      @approval.update!(status: :approved, executed_at: Time.current, result_payload: { value: result })
    end

    redirect_to mcp_approval_path(@approval), notice: "Operation approved and executed."
  rescue Pundit::NotAuthorizedError
    redirect_to mcp_approval_path(@approval), alert: "You are not authorized to perform this operation."
  rescue StandardError => e
    Rails.logger.error("[mcp_approval] #{e.class}: #{e.message}")
    redirect_to mcp_approval_path(@approval), alert: "Could not execute operation: #{e.message}"
  end

  # POST /mcp/approvals/:id/reject
  def reject
    return redirect_to mcp_approval_path(@approval), alert: stale_alert unless @approval.resolvable?

    @approval.update!(status: :rejected)
    redirect_to mcp_approval_path(@approval), notice: "Operation rejected."
  end

  private

  def load_approval
    @approval = ActsAsTenant.without_tenant do
      Mcp::PendingApproval.find(params[:id])
    end

    # An approval URL is the secret — it's only useful to the user who
    # initiated it. Refuse any other browser session, even one signed in
    # to the same tenant.
    return if @approval.user_id == current_user.id

    redirect_to root_path, alert: "Not found."
  end

  def stale_alert
    case @approval.status
    when "approved" then "Already approved."
    when "rejected" then "Already rejected."
    when "expired"  then "This approval has expired."
    else "This approval is no longer pending."
    end
  end
end

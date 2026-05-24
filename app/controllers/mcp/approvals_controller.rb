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
    authorize @approval
    render Views::Mcp::Approvals::ShowView.new(approval: @approval)
  end

  # POST /mcp/approvals/:id/approve
  #
  # Atomic transition: lock the row, re-check resolvability inside the
  # transaction, then dispatch the operation. Without the row lock, two
  # concurrent approve clicks could both pass the `resolvable?` check
  # and execute the underlying operation twice.
  def approve
    authorize @approval

    Mcp::PendingApproval.transaction do
      locked = ActsAsTenant.without_tenant { Mcp::PendingApproval.lock.find(@approval.id) }
      unless locked.resolvable?
        @approval = locked
        return redirect_to mcp_approval_path(@approval), alert: stale_alert
      end

      ActsAsTenant.with_tenant(locked.tenant) do
        result = locked.operation.call(context: approval_context(locked), params: locked.arguments)
        locked.update!(status: :approved, executed_at: Time.current, result_payload: { value: result })
      end
      @approval = locked
    end

    redirect_to mcp_approval_path(@approval), notice: "Operation approved and executed."
  rescue Pundit::NotAuthorizedError
    redirect_to mcp_approval_path(@approval), alert: "You are not authorized to perform this operation."
  rescue StandardError => e
    # Surface a generic alert — exception messages can leak internal
    # state (record IDs, SQL fragments, etc) and the user has no way to
    # act on them. Full detail goes to the logs for ops triage.
    Rails.logger.error("[mcp_approval] #{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
    redirect_to mcp_approval_path(@approval), alert: "Could not execute operation. The error has been logged."
  end

  # POST /mcp/approvals/:id/reject
  #
  # Same row-lock + re-check pattern as #approve. Without it, an approve
  # racing a reject on the same row could let both succeed (the second
  # write silently overwriting the first), leaving the operation
  # executed but the row marked rejected.
  def reject
    authorize @approval

    Mcp::PendingApproval.transaction do
      locked = ActsAsTenant.without_tenant { Mcp::PendingApproval.lock.find(@approval.id) }
      unless locked.resolvable?
        @approval = locked
        return redirect_to mcp_approval_path(@approval), alert: stale_alert
      end

      locked.update!(status: :rejected)
      @approval = locked
    end

    redirect_to mcp_approval_path(@approval), notice: "Operation rejected."
  end

  private

  def load_approval
    @approval = ActsAsTenant.without_tenant do
      Mcp::PendingApproval.find_by(id: params[:id])
    end

    # An approval URL is the secret — it's only useful to the user who
    # initiated it. Refuse any other browser session, even one signed in
    # to the same tenant. Same "Not found." for a bad/missing id so we
    # don't leak whether a given approval id exists.
    return if @approval && @approval.user_id == current_user.id

    redirect_to root_path, alert: "Not found."
  end

  # Rebuilds the AuthorizationContext against the approval's tenant — the
  # tenant the MCP token was bound to at consent time, which may differ
  # from the user's currently-active web session tenant.
  def approval_context(approval)
    tenant_user = ActsAsTenant.without_tenant do
      TenantUser.find_by(tenant_id: approval.tenant_id, user_id: current_user.id)
    end
    AuthorizationContext.new(
      user: current_user,
      tenant_user: tenant_user,
      person: tenant_user&.person
    )
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

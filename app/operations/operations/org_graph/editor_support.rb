# frozen_string_literal: true

# What the Org Graph editor operations share: finding a person's accounts in
# the tenant, and the list as it reads after a change.
module Operations::OrgGraph::EditorSupport
  include Operations::GrantHoldersPayload
  include Operations::PersonAccounts

  private

  # @raise [Pundit::NotAuthorizedError] unless the caller is a tenant admin
  def policy_check
    authorize ActsAsTenant.current_tenant, :manage_org_graph_editors?, policy_class: TenantPolicy
  end

  def grant_handler
    AccountGrants::CommandHandler.new
  end

  # Admins may always edit, so they are listed apart from the editors an admin chose.
  def editors_payload = grant_holders_payload(:org_graph_editor, :editors)
end

# frozen_string_literal: true

# Per-tenant Slack connection. Slack is installed per tenant (workspace), while
# users' notification preferences are cross-tenant — so the bot token lives on
# the Tenant, and the recipient's per-workspace Slack user id is cached on the
# TenantUser.
#
#   tenants.slack_credentials — encrypted JSON: { bot_token:, team_name:, installed_by: }
#   tenants.slack_team_id      — the Slack workspace/team id (plain, for inbound
#                                routing in a later phase); unique when present.
#   tenant_users.slack_user_id — cached Slack user id resolved by email lookup.
class AddSlackToTenantsAndTenantUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :slack_credentials, :string
    add_column :tenants, :slack_team_id, :string
    add_index :tenants, :slack_team_id, unique: true, where: "slack_team_id IS NOT NULL"

    add_column :tenant_users, :slack_user_id, :string
  end
end

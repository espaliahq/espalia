# frozen_string_literal: true

# Backs the in-app approval handoff for high-stakes MCP operations
# (publish framework version, close cycle, grant collaborator, etc).
# When an MCP client invokes a tool declared `approval :in_app`, the
# server creates a row here and returns a URL the user opens in the
# web UI to review and approve — execution happens in that controller,
# never in the MCP request itself. See Mcp::PendingApproval.
class CreateMcpPendingApprovals < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_pending_approvals, id: :uuid, default: nil do |t|
      t.references :user,                 null: false, type: :uuid, foreign_key: true
      t.references :tenant,               null: false, type: :uuid, foreign_key: true
      t.references :client_application,   null: false, type: :uuid,
                                          foreign_key: { to_table: :oauth_applications }
      t.string  :operation_class, null: false       # e.g. "Operations::Frameworks::PublishVersion"
      t.jsonb   :arguments,       null: false, default: {}
      t.integer :status,          null: false, default: 0 # enum: pending/approved/rejected/expired
      t.datetime :expires_at,     null: false
      t.datetime :executed_at
      t.jsonb    :result_payload                       # operation return value once executed

      t.timestamps
    end

    add_index :mcp_pending_approvals, [ :tenant_id, :status, :expires_at ]
    add_index :mcp_pending_approvals, :user_id, where: "status = 0", name: "idx_mcp_pending_approvals_pending_by_user"
  end
end

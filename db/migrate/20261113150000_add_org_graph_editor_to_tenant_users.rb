# frozen_string_literal: true

# The Org Graph editor grant: a tenant-level right for the people team to edit
# any unit and membership, held alongside the member or admin role.
class AddOrgGraphEditorToTenantUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :tenant_users, :org_graph_editor, :boolean, default: false, null: false
  end
end

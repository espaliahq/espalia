# frozen_string_literal: true

class AddOrgGraphConfigToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :org_graph_config, :jsonb, default: {}, null: false
  end
end

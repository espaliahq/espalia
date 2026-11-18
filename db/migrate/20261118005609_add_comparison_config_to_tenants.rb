# frozen_string_literal: true

class AddComparisonConfigToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :comparison_config, :jsonb, default: {}, null: false
  end
end

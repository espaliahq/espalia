# frozen_string_literal: true

class AddHrisConfigToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :hris_config, :jsonb, null: false, default: {}
    add_column :tenants, :hris_credentials, :string
  end
end

# frozen_string_literal: true

class AddTimeZoneToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :time_zone, :string, null: false, default: "UTC"
  end
end

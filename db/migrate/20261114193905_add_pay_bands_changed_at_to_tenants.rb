# frozen_string_literal: true

class AddPayBandsChangedAtToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :pay_bands_changed_at, :datetime
  end
end

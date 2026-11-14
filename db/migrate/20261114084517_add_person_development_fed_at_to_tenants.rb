# frozen_string_literal: true

class AddPersonDevelopmentFedAtToTenants < ActiveRecord::Migration[8.1]
  def change
    add_column :tenants, :person_development_fed_at, :datetime
  end
end

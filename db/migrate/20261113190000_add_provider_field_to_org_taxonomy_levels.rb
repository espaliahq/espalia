# frozen_string_literal: true

class AddProviderFieldToOrgTaxonomyLevels < ActiveRecord::Migration[8.1]
  def change
    add_column :org_taxonomy_levels, :provider_field, :string
  end
end

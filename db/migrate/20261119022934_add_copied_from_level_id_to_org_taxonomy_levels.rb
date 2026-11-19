# frozen_string_literal: true

class AddCopiedFromLevelIdToOrgTaxonomyLevels < ActiveRecord::Migration[8.1]
  def change
    add_column :org_taxonomy_levels, :copied_from_level_id, :uuid
  end
end

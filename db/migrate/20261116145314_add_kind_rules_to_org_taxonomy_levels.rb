# frozen_string_literal: true

# A kind's stated rules for where its units may sit. Null on a kind that never
# stated them: OrgGraph::Taxonomy derives the legacy rule from its place.
class AddKindRulesToOrgTaxonomyLevels < ActiveRecord::Migration[8.1]
  def change
    add_column :org_taxonomy_levels, :parent_level_ids, :uuid, array: true
    add_column :org_taxonomy_levels, :top, :boolean
  end
end

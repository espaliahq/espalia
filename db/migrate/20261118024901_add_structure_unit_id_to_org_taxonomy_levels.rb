# frozen_string_literal: true

# A unit may declare a structure of its own (#494). Its types sit beside the
# top structure's, numbered from zero within their own structure; nil is the top.
class AddStructureUnitIdToOrgTaxonomyLevels < ActiveRecord::Migration[8.0]
  def change
    add_column :org_taxonomy_levels, :structure_unit_id, :uuid
    add_index :org_taxonomy_levels, %i[tenant_id structure_unit_id position], unique: true, nulls_not_distinct: true,
                                                                              name: "index_org_taxonomy_levels_on_structure_position"
    remove_index :org_taxonomy_levels, %i[tenant_id position], unique: true,
                                                               name: "index_org_taxonomy_levels_on_tenant_id_and_position"
  end
end

# frozen_string_literal: true

# Who supplies each taxonomy level and each kind of person fact, projected from
# the tenant's OrgStructure stream. Anything without a row is Espalia's.
class AddOrgGraphProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :org_taxonomy_levels, :provider, :string, null: false, default: "espalia"
    add_column :org_taxonomy_levels, :provider_effective_on, :date

    create_table :org_fact_providers, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :fact, null: false
      t.string :provider, null: false
      t.date :effective_on, null: false
      t.timestamps
    end
    add_index :org_fact_providers, %i[tenant_id fact], unique: true
  end
end

# frozen_string_literal: true

# When each fact Espalia holds about a person was last changed or confirmed,
# projected from the person streams by OrgGraph::Projections::FactAges. A
# person who has left has a row of their own, whose fact is "left".
class CreateOrgFactAges < ActiveRecord::Migration[8.1]
  def change
    create_table :org_fact_ages, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :person_id, null: false
      t.string :fact, null: false
      t.uuid :unit_id
      t.jsonb :value
      t.datetime :changed_at, null: false
      t.datetime :confirmed_at
      t.datetime :checked_at, null: false
      t.uuid :checked_by_id
      t.timestamps
    end
    add_index :org_fact_ages, %i[tenant_id person_id fact unit_id], unique: true, nulls_not_distinct: true,
      name: "index_org_fact_ages_on_fact"
    add_index :org_fact_ages, %i[tenant_id checked_at]
  end
end

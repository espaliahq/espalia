# frozen_string_literal: true

# Each person who has left and the day they left, projected from the person
# streams by OrgGraph::Projections::Leavers. A tenant's retention period runs
# from that day.
class CreateOrgLeavers < ActiveRecord::Migration[8.1]
  def change
    create_table :org_leavers, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :person_id, null: false
      t.date :left_on, null: false
      t.timestamps
    end
    add_index :org_leavers, %i[tenant_id person_id], unique: true
    add_index :org_leavers, %i[tenant_id left_on]
  end
end

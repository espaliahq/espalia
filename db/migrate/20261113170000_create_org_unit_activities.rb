# frozen_string_literal: true

# Each change to a unit or its memberships, one row per unit the event
# touches, projected from the Org Graph streams by
# OrgGraph::Projections::UnitActivity.
class CreateOrgUnitActivities < ActiveRecord::Migration[8.1]
  def change
    create_table :org_unit_activities, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :unit_id, null: false
      t.uuid :event_id, null: false
      t.string :event_type, null: false
      t.bigint :position, null: false
      t.string :subject
      t.uuid :person_id
      t.uuid :other_unit_id
      t.uuid :actor_id
      t.string :provider
      t.jsonb :before
      t.jsonb :after
      t.date :effective_on
      t.datetime :learned_at, null: false
      t.string :causation_id
      t.string :correlation_id
      t.uuid :changes_back_id
      t.uuid :changed_back_by_id
      t.timestamps
    end
    add_index :org_unit_activities, %i[tenant_id event_id unit_id], unique: true
    add_index :org_unit_activities, %i[tenant_id unit_id position]
    add_index :org_unit_activities, %i[tenant_id unit_id subject position]
  end
end

# frozen_string_literal: true

# The keys that encrypt a plan's shreddable fields. A destroyed key keeps its
# row, with no key material, so nothing mints a fresh one in its place.
class CreatePlanEncryptionKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :plan_encryption_keys, id: :uuid do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :plan_id, null: false
      t.uuid :person_id
      t.string :cipher, null: false
      t.text :key_material
      t.datetime :destroyed_at
      t.string :destroyed_reason
      t.timestamps

      t.index %i[tenant_id plan_id], unique: true, where: "person_id IS NULL", name: "index_plan_keys_one_per_plan"
      t.index %i[tenant_id plan_id person_id], unique: true, where: "person_id IS NOT NULL",
                                               name: "index_plan_keys_one_per_person_in_plan"
      t.index %i[tenant_id person_id], where: "person_id IS NOT NULL", name: "index_plan_keys_on_person"
      t.check_constraint "(destroyed_at IS NULL AND key_material IS NOT NULL) OR " \
                         "(destroyed_at IS NOT NULL AND key_material IS NULL AND destroyed_reason IS NOT NULL)",
                         name: "plan_encryption_keys_live_or_destroyed"
    end
  end
end

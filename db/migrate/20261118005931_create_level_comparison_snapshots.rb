# frozen_string_literal: true

# The group scores a level comparison shows: each snapshot, and each group's
# size and middle scores in it. Only medians and counts, never a person.
class CreateLevelComparisonSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :level_comparison_snapshots, id: :uuid, default: nil do |t|
      t.uuid :tenant_id, null: false
      t.date :taken_on, null: false
      t.timestamps
      t.index [ :tenant_id, :taken_on ], unique: true
    end

    create_table :level_comparison_groups, id: :uuid, default: nil do |t|
      t.uuid :tenant_id, null: false
      t.references :snapshot, type: :uuid, null: false, index: false,
                              foreign_key: { to_table: :level_comparison_snapshots, on_delete: :cascade }
      t.uuid :framework_id, null: false
      t.uuid :role_id, null: false
      t.integer :level_ordinal, null: false
      t.integer :group_size, null: false
      t.jsonb :capability_medians, null: false, default: {}
      t.jsonb :category_medians, null: false, default: {}
      t.timestamps
      t.index [ :snapshot_id, :role_id, :level_ordinal ], unique: true
    end
  end
end

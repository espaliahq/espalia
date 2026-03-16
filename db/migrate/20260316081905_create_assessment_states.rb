class CreateAssessmentStates < ActiveRecord::Migration[8.1]
  def change
    create_table :assessment_states, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :person_id, null: false
      t.uuid :framework_id, null: false
      t.uuid :capability_stable_id, null: false
      t.uuid :cycle_id
      t.uuid :self_rated_level_id
      t.uuid :manager_rated_level_id
      t.uuid :aligned_level_id
      t.datetime :last_self_rated_at
      t.datetime :last_aligned_at
      t.string :migration_status, default: "not_flagged", null: false
      t.text :reassessment_reason
      t.timestamps
    end

    add_index :assessment_states, [ :person_id, :framework_id, :capability_stable_id ],
              unique: true, name: "idx_assessment_states_person_framework_capability"
    add_index :assessment_states, [ :person_id, :framework_id ]
  end
end

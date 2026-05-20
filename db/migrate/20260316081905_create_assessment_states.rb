# frozen_string_literal: true

class CreateAssessmentStates < ActiveRecord::Migration[8.1]
  def change
    create_table :assessment_level_ratings, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :person_id,            null: false
      t.uuid :framework_id,         null: false
      t.uuid :capability_stable_id, null: false
      t.integer :level_ordinal,     null: false
      t.uuid :cycle_id,             null: false

      t.string :self_rated_frequency       # nil | "some" | "occasional" | "consistent"
      t.string :manager_rated_frequency    # nil | "some" | "occasional" | "consistent"
      t.string :aligned_frequency          # nil | "some" | "occasional" | "consistent"
      t.string :source, default: "human", null: false  # "human" | "agent" | "seeded"
      t.uuid :seeded_from_cycle_id  # set when source == "seeded"

      t.text :self_rated_comment
      t.text :manager_rated_comment
      t.text :aligned_comment

      t.datetime :last_self_rated_at
      t.datetime :last_manager_rated_at
      t.datetime :last_aligned_at

      t.string :migration_status, default: "not_flagged", null: false
      t.text :reassessment_reason
      t.timestamps
    end

    add_index :assessment_level_ratings,
              [ :cycle_id, :person_id, :framework_id, :capability_stable_id, :level_ordinal ],
              unique: true, name: "idx_assessment_ratings_cycle_person_cap_level"
    add_index :assessment_level_ratings, [ :person_id, :framework_id ]
    add_index :assessment_level_ratings, [ :cycle_id, :person_id ],
              name: "idx_assessment_ratings_cycle_person"
    add_index :assessment_level_ratings, :seeded_from_cycle_id,
              where: "seeded_from_cycle_id IS NOT NULL",
              name: "idx_assessment_ratings_seeded_from_cycle_id"
  end
end

# frozen_string_literal: true

# Declared explorations (ADR-22): one row per `ExplorationStarted`, keyed by
# the event-carried exploration id so a projection rebuild reproduces the id
# a URL or an MCP client holds. At most one open exploration per person,
# framework and target role — the aggregate's rule, mirrored as a partial
# unique index.
class CreateAssessmentExplorations < ActiveRecord::Migration[8.1]
  def change
    create_table :assessment_explorations, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: true
      t.uuid :person_id, null: false
      t.uuid :framework_id, null: false
      t.uuid :target_role_id, null: false
      t.uuid :target_level_id, null: false
      t.integer :target_level_ordinal
      t.string :status, null: false, default: "open"
      t.datetime :started_at, null: false
      t.uuid :started_by_id
      t.text :start_note
      t.datetime :closed_at
      t.uuid :closed_by_id
      t.string :outcome
      t.text :close_note
      t.timestamps
    end

    add_index :assessment_explorations, %i[person_id framework_id],
      name: "idx_assessment_explorations_by_person"
    add_index :assessment_explorations, %i[person_id framework_id target_role_id],
      unique: true, where: "status = 'open'", name: "idx_assessment_explorations_one_open_per_role"
  end
end

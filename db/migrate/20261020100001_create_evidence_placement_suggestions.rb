# frozen_string_literal: true

# Machine-proposed cells (capability × level + valence) for a piece of
# feedback, waiting for a person to accept, adjust or dismiss them. Plain
# state, not a read model: the suggestions are regenerable model output, and
# the human decision is what the event stream records (via_suggestion_id on
# the link events). No foreign key to evidence_items, which a projection
# rebuild truncates and replays.
class CreateEvidencePlacementSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :evidence_placement_suggestions, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: true
      t.uuid :evidence_id, null: false
      t.uuid :person_id, null: false
      t.uuid :framework_id, null: false
      t.uuid :capability_stable_id, null: false
      t.integer :level_ordinal, null: false
      t.string :valence, null: false
      t.decimal :confidence, precision: 3, scale: 2, null: false
      t.text :rationale, null: false
      t.string :status, null: false, default: "pending"
      t.uuid :decided_by_id
      t.datetime :decided_at
      t.text :dismiss_reason
      t.string :model, null: false
      t.string :prompt_version, null: false
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :evidence_placement_suggestions, %i[evidence_id capability_stable_id level_ordinal],
      unique: true, name: "idx_evidence_placement_suggestions_cell"
    add_index :evidence_placement_suggestions, %i[person_id framework_id status],
      name: "idx_evidence_placement_suggestions_person"
  end
end

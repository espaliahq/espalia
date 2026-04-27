# frozen_string_literal: true

class CreateAssessmentCycleParticipants < ActiveRecord::Migration[8.1]
  def change
    create_table :assessment_cycle_participants, id: :uuid do |t|
      t.references :tenant, type: :uuid, foreign_key: true, null: false
      t.uuid :cycle_id, null: false
      t.uuid :person_id, null: false
      t.string :status, null: false, default: "enrolled"
      # enrolled | started | self_complete | manager_complete | aligning | aligned | withdrawn
      t.datetime :enrolled_at, null: false
      t.datetime :started_at
      t.datetime :self_completed_at
      t.datetime :manager_completed_at
      t.datetime :alignment_started_at
      t.uuid :alignment_started_by_id
      t.datetime :aligned_at
      t.datetime :withdrawn_at
      t.string :withdrawal_reason
      t.timestamps
    end

    add_index :assessment_cycle_participants, [ :cycle_id, :person_id ], unique: true,
              name: "idx_assessment_cycle_participants_unique"
    add_index :assessment_cycle_participants, [ :tenant_id, :person_id, :status ],
              name: "idx_assessment_cycle_participants_by_person_status"
  end
end

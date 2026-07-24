# frozen_string_literal: true

class CreateCalibrationSessions < ActiveRecord::Migration[8.1]
  def change
    # PK is the event-carried session_id (set by the projection), so the
    # row's external identity survives reset! + replay — see
    # docs/guidelines/event-sourcing.md "Externally-addressable read-model
    # identity must be deterministic".
    create_table :calibration_sessions, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :cycle_id, null: false
      t.uuid :framework_id, null: false
      t.integer :framework_version
      t.string :name, null: false
      t.uuid :facilitator_id, null: false
      t.string :status, null: false, default: "draft"
      t.uuid :defined_by
      t.uuid :started_by_id
      t.datetime :started_at
      t.uuid :closed_by_id
      t.string :close_reason
      t.datetime :closed_at
      t.timestamps
    end
    add_index :calibration_sessions, [ :tenant_id, :cycle_id ]
    add_index :calibration_sessions, :facilitator_id
    add_index :calibration_sessions, :status

    create_table :calibration_session_members, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :session_id, null: false
      t.uuid :person_id, null: false
      t.string :member_type, null: false # participant | calibrant
      t.uuid :added_by
      t.timestamps
    end
    # A person holds at most one role in a session (the raters-excluded
    # invariant means participant and calibrant are mutually exclusive).
    add_index :calibration_session_members, [ :session_id, :person_id ], unique: true
    add_index :calibration_session_members, [ :session_id, :member_type ]
    add_index :calibration_session_members, :person_id
  end
end

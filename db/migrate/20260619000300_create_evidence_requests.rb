# frozen_string_literal: true

# Read model for cell-scoped evidence requests, projected from the
# PersonDevelopment stream (EvidenceRequested / …Responded / …Declined /
# …Cancelled). The PK is the event-carried request_id so it is replay-stable
# and safe to address from inbox links and Slack deep links.
class CreateEvidenceRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :evidence_requests, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true
      t.uuid :person_id, null: false              # the assessee
      t.uuid :framework_id, null: false
      t.uuid :requested_by_id, null: false
      t.uuid :requestee_person_id, null: false
      t.uuid :capability_stable_id, null: false
      t.integer :level_ordinal, null: false
      t.text :message
      t.datetime :due_at
      t.string :status, null: false, default: "pending"
      t.uuid :evidence_id                          # set when responded
      t.text :decline_reason
      t.datetime :requested_at, null: false
      t.datetime :responded_at
      t.datetime :declined_at
      t.datetime :cancelled_at
      t.timestamps
    end

    add_index :evidence_requests, :requestee_person_id            # incoming inbox
    add_index :evidence_requests, :requested_by_id                # outgoing list
    add_index :evidence_requests, [ :person_id, :framework_id ]   # per-assessment
    add_index :evidence_requests, :status
    add_foreign_key :evidence_requests, :people, column: :requestee_person_id, on_delete: :cascade
    add_foreign_key :evidence_requests, :people, column: :requested_by_id, on_delete: :cascade
  end
end

# frozen_string_literal: true

# The consumer's ledger: one row per record a peer has sent (protocol §2.4),
# keyed on (origin, external_id), saying what became of it.
class CreateFeedbackExchangeImports < ActiveRecord::Migration[8.1]
  def change
    create_table :feedback_exchange_imports, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.string :origin, null: false
      t.string :external_id, null: false
      t.uuid :evidence_id
      t.uuid :recipient_id
      t.string :status, null: false
      t.string :skip_reason
      t.jsonb :record
      t.datetime :peer_updated_at
      t.datetime :synced_at, null: false
      t.timestamps
    end

    add_index :feedback_exchange_imports, %i[tenant_id origin external_id], unique: true,
              name: "index_feedback_exchange_imports_on_origin_key"
    add_index :feedback_exchange_imports, %i[tenant_id status skip_reason], name: "index_feedback_exchange_imports_on_status"
    add_index :feedback_exchange_imports, %i[tenant_id recipient_id], where: "status = 'skipped'",
              name: "index_feedback_exchange_imports_on_skipped_recipient"
  end
end

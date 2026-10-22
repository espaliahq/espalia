# frozen_string_literal: true

# Where a peer system says one of our evidence items now also lives. The peer
# acknowledges each item it imports; we show an "Also in <peer>" link and keep
# the item out of the reverse direction. State written by the producer
# endpoint, not projected from events, so a projection rebuild leaves it alone.
class CreateFeedbackExchangeAcks < ActiveRecord::Migration[8.1]
  def change
    create_table :feedback_exchange_acks, id: :uuid, default: nil do |t|
      t.references :tenant, type: :uuid, null: false, foreign_key: true, index: false
      t.uuid :evidence_id, null: false
      t.string :consumer, null: false
      t.string :remote_id, null: false
      t.string :remote_url
      t.timestamps
    end
    add_index :feedback_exchange_acks, %i[tenant_id evidence_id consumer],
              unique: true, name: "idx_feedback_exchange_acks_item_consumer"
  end
end

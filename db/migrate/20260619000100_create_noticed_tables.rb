# frozen_string_literal: true

# Noticed (v3) storage tables, hand-written for this app's UUID primary keys.
#
# Noticed's own models (Noticed::Event / Noticed::Notification) inherit the
# gem's ApplicationRecord, not ours, so they never run the UUID-v7
# before_create callback. We give these internal tables a DB-side
# gen_random_uuid() (v4) default — they are queried by recipient + recency,
# not externally addressed by id, so v4 is fine and avoids NULL-PK inserts.
class CreateNoticedTables < ActiveRecord::Migration[8.1]
  def change
    create_table :noticed_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :type
      t.belongs_to :record, polymorphic: true, type: :uuid
      t.jsonb :params
      t.integer :notifications_count

      t.timestamps
    end

    create_table :noticed_notifications, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :type
      t.belongs_to :event, null: false, type: :uuid
      t.belongs_to :recipient, polymorphic: true, null: false, type: :uuid
      t.datetime :read_at
      t.datetime :seen_at

      t.timestamps
    end
  end
end

# frozen_string_literal: true

# Per-user notification preferences. Stored on the global User (NOT tenant
# scoped) because a user's channel choices follow them across every tenant
# they belong to. The JSONB holds only explicit overrides keyed by
# notification type then channel, e.g.:
#
#   { "evidence_requested" => { "slack" => false } }
#
# Absent keys fall back to the code-defined defaults in NotificationType, so
# adding a new notification type never needs a backfill.
class AddNotificationPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :notification_preferences, :jsonb, default: {}, null: false
  end
end

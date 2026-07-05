# frozen_string_literal: true

# Append-only reminder history + a last-reminded stamp, projected from
# EvidenceRequestReminderSent. History powers the hub's per-request timeline;
# last_reminded_at powers staleness sorting and both spacing rules (the
# automatic 3-day gap and the manual 2-day nudge gap). Future-events-only in
# production — no rebuild needed.
class AddReminderHistoryToEvidenceRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence_requests, :reminder_history, :jsonb, default: [], null: false
    add_column :evidence_requests, :last_reminded_at, :datetime
  end
end

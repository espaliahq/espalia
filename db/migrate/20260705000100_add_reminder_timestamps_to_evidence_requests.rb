# frozen_string_literal: true

# Per-kind reminder stamps on evidence requests, projected from
# EvidenceRequestReminderSent. Read-model columns populated only by future
# events — no projection rebuild needed (see docs/guidelines/event-sourcing.md).
class AddReminderTimestampsToEvidenceRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence_requests, :no_response_reminded_at, :datetime
    add_column :evidence_requests, :due_soon_reminded_at, :datetime
  end
end

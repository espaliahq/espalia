# frozen_string_literal: true

# Composite index matching the hourly reminder sweep's eligibility query
# (`status = 'pending' AND requested_at BETWEEN ...`) so it doesn't lean on
# the standalone status index as tenants accumulate resolved requests.
class IndexEvidenceRequestsForReminderSweep < ActiveRecord::Migration[8.1]
  def change
    add_index :evidence_requests, [ :status, :requested_at ]
  end
end

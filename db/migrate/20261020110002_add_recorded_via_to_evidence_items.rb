# frozen_string_literal: true

# The surface an item was recorded through (web, mcp, slack, hris, system,
# feedback_exchange), projected from the event's `acting_via` metadata. The
# feedback exchange feed reads it to leave out items no person wrote. Nil on
# history; a rebuild of the projection backfills it.
class AddRecordedViaToEvidenceItems < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence_items, :recorded_via, :string
    # The producer feed pages one tenant's items by (updated_at, id).
    add_index :evidence_items, %i[tenant_id updated_at id], name: "idx_evidence_items_feed"
  end
end

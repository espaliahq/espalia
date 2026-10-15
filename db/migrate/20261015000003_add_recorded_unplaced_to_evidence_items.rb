# frozen_string_literal: true

# Whether an item was given without a capability in mind. Its first placement
# becomes its origin, so without this fact the feed would later read as if
# the author had chosen the cell. Every existing row was recorded placed.
class AddRecordedUnplacedToEvidenceItems < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence_items, :recorded_unplaced, :boolean, null: false, default: false
  end
end

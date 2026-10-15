# frozen_string_literal: true

# Feedback can now be recorded without a capability × level in mind and placed
# later, so an item's origin cell is optional. Every existing row keeps its
# cell; only items recorded unplaced from here on carry nulls.
class AllowUnplacedEvidenceItems < ActiveRecord::Migration[8.1]
  def change
    change_column_null :evidence_items, :capability_stable_id, true
    change_column_null :evidence_items, :level_ordinal, true
  end
end

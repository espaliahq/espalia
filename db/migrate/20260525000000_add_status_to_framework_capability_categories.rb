# frozen_string_literal: true

# Mirrors the `status` column on `framework_capabilities`: lets the
# PublishedState projection mark a category as `archived` without
# deleting the row (we keep it for historical / audit reasons, and to
# preserve `category_id` references on archived capabilities and on
# any past suggestion / collaborator rows scoped to this category).
#
# Default "active" backfills existing rows automatically; this column
# is populated entirely by the projection, so no separate backfill is
# required beyond a `CODE_VERSION` bump (the projection's `reset!` +
# replay will re-stamp every row at "active" by default).
class AddStatusToFrameworkCapabilityCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :framework_capability_categories, :status, :string,
               default: "active", null: false
  end
end

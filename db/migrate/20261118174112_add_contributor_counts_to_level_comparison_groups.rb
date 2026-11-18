# frozen_string_literal: true

# How many people each capability and category median rests on, so a reader
# can withhold one under the tenant's smallest group. Snapshots taken without
# counts are derived data and are deleted: the hourly job takes a fresh one
# for any tenant with comparisons on and none left.
class AddContributorCountsToLevelComparisonGroups < ActiveRecord::Migration[8.1]
  def change
    add_column :level_comparison_groups, :capability_counts, :jsonb, default: {}, null: false
    add_column :level_comparison_groups, :category_counts, :jsonb, default: {}, null: false

    up_only { execute "DELETE FROM level_comparison_snapshots" }
  end
end

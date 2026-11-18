# frozen_string_literal: true

# Everyone on one role at one level in a snapshot: how many there were, and
# their median score on each capability and each category, on the hero's
# scale (1.0 is the level met), with how many people each median rests on.
class LevelComparisonGroup < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :snapshot, class_name: "LevelComparisonSnapshot", inverse_of: :groups

  # @param min_group_size [Integer] the tenant's smallest group
  # @return [Hash{String => Float}] stable_id => median, only those at least min_group_size people rest on
  def capability_medians_shown(min_group_size) = shown(capability_medians, capability_counts, min_group_size)

  # @param min_group_size [Integer] the tenant's smallest group
  # @return [Hash{String => Float}] category_id => median, only those at least min_group_size people rest on
  def category_medians_shown(min_group_size) = shown(category_medians, category_counts, min_group_size)

  private

  # A median with no count, from a snapshot taken before counts were kept, is withheld.
  def shown(medians, counts, min_group_size)
    medians.select { |id, _| counts[id].to_i >= min_group_size }
  end
end

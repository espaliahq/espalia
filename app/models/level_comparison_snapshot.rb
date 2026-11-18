# frozen_string_literal: true

# The group scores a level comparison shows, as they stood on one day. Taken
# on the 1st of the month, so a change to one person's rating reaches the
# group's middle score only with everyone else's changes since the last one.
class LevelComparisonSnapshot < ApplicationRecord
  acts_as_tenant :tenant

  has_many :groups, class_name: "LevelComparisonGroup", foreign_key: :snapshot_id, inverse_of: :snapshot,
                    dependent: :delete_all

  # @param tenant [Tenant]
  # @param on [Date] the day it is taken, the tenant's today
  # @return [LevelComparisonSnapshot] the tenant's snapshot for that day, replaced if it already had one
  def self.take!(tenant:, on:)
    groups = LevelComparisons::GroupScores.new(tenant:).call
    transaction do
      where(tenant:, taken_on: on).destroy_all
      create!(tenant:, taken_on: on).tap do |snapshot|
        groups.each { |group| snapshot.groups.create!(tenant:, **group) }
      end
    end
  end

  # @return [LevelComparisonSnapshot, nil] the snapshot comparisons show now
  def self.latest = order(taken_on: :desc).first

  # @param role_id [String]
  # @param level_ordinal [Integer]
  # @return [LevelComparisonGroup, nil] nil when nobody on the role at the level had a settled assessment
  def group_for(role_id:, level_ordinal:)
    groups.find { |group| group.role_id == role_id && group.level_ordinal == level_ordinal }
  end
end

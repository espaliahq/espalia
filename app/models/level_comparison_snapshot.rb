# frozen_string_literal: true

# The group scores a level comparison shows, as they stood on one day. Taken
# on the 1st of the month, so a change to one person's rating reaches the
# group's median only with everyone else's changes since the last one.
class LevelComparisonSnapshot < ApplicationRecord
  # How a snapshot's day reads on screen: "1 Nov 2026".
  DATE_FORMAT = "%-d %b %Y"

  acts_as_tenant :tenant

  has_many :groups, class_name: "LevelComparisonGroup", foreign_key: :snapshot_id, inverse_of: :snapshot,
                    dependent: :delete_all

  # @param tenant [Tenant]
  # @param on [Date] the day it is taken, the tenant's today
  # @return [LevelComparisonSnapshot] the tenant's snapshot for that day, replaced if it already had one
  def self.take!(tenant:, on:)
    groups = LevelComparisons::GroupScores.new(tenant:).call
    ActsAsTenant.with_tenant(tenant) do
      transaction do
        where(taken_on: on).destroy_all
        create!(taken_on: on).tap { |snapshot| groups.each { |group| snapshot.groups.create!(**group) } }
      end
    end
  end

  # @return [LevelComparisonSnapshot, nil] the snapshot comparisons show now
  def self.latest = order(taken_on: :desc).first

  # @return [Boolean] false for one taken before contributor counts were kept,
  #   whose medians are all withheld until it is retaken
  def counted? = groups.none? { |group| group.capability_counts.empty? && group.capability_medians.any? }
end

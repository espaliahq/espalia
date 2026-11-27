# frozen_string_literal: true

# A tenant's settings for comparing a person with others on their role at a
# level, stored in Tenant.comparison_config JSONB.
#
# @example
#   tenant.comparison_config.min_group_size # => 5
class ComparisonConfig
  include StoreModel::Model

  DEFAULT_MIN_GROUP_SIZE = 5
  # Smaller groups could point at one person, in a comparison or the capability attainment report.
  LOWEST_MIN_GROUP_SIZE = 4
  HIGHEST_MIN_GROUP_SIZE = 100
  SNAPSHOT_INTERVALS = [ 1, 3, 6 ].freeze

  # The size a floor applies, never below the least an admin may set, so a
  # value the validation would refuse can't open it.
  #
  # @param size [Integer, String, nil] a size as stored
  # @return [Integer]
  def self.floor_for(size) = [ Integer(size.to_s, 10, exception: false).to_i, LOWEST_MIN_GROUP_SIZE ].max

  attribute :enabled, :boolean, default: true
  # The fewest people a group needs before its scores show on the comparison
  # tab, and in the capability attainment report to a viewer who can't open
  # every assessment in the group.
  attribute :min_group_size, :integer, default: DEFAULT_MIN_GROUP_SIZE
  attribute :snapshot_every_months, :integer, default: SNAPSHOT_INTERVALS.first

  validates :min_group_size, numericality: {
    only_integer: true, greater_than_or_equal_to: LOWEST_MIN_GROUP_SIZE, less_than_or_equal_to: HIGHEST_MIN_GROUP_SIZE,
    message: "must be a whole number, at least #{LOWEST_MIN_GROUP_SIZE} and at most #{HIGHEST_MIN_GROUP_SIZE}"
  }
  validates :snapshot_every_months, inclusion: { in: SNAPSHOT_INTERVALS, message: "must be 1, 3 or 6" }

  # The 1st of the month the next snapshot is due on, counted from the month
  # of the last one, so a shorter interval can leave one overdue.
  #
  # @param last_taken_on [Date, nil]
  # @param today [Date] the tenant's today
  # @return [Date] today when none has been taken yet, or one is overdue
  def next_snapshot_on(last_taken_on, today:)
    return today unless last_taken_on

    [ last_taken_on.beginning_of_month >> snapshot_every_months, today ].max
  end
end

# frozen_string_literal: true

# A tenant's settings for comparing a person with others on their role at a
# level, stored in Tenant.comparison_config JSONB.
#
# @example
#   tenant.comparison_config.min_group_size # => 5
class ComparisonConfig
  include StoreModel::Model

  DEFAULT_MIN_GROUP_SIZE = 5
  # The capability attainment report's floor before this setting existed, so
  # no tenant can show smaller groups than it did.
  LOWEST_MIN_GROUP_SIZE = 4
  HIGHEST_MIN_GROUP_SIZE = 100
  SNAPSHOT_INTERVALS = [ 1, 3, 6 ].freeze

  attribute :enabled, :boolean, default: true
  # The fewest people a group needs before its scores show, on the comparison
  # tab and in the capability attainment report.
  attribute :min_group_size, :integer, default: DEFAULT_MIN_GROUP_SIZE
  attribute :snapshot_every_months, :integer, default: SNAPSHOT_INTERVALS.first

  validates :min_group_size, numericality: {
    only_integer: true, greater_than_or_equal_to: LOWEST_MIN_GROUP_SIZE, less_than_or_equal_to: HIGHEST_MIN_GROUP_SIZE,
    message: "must be a whole number, at least #{LOWEST_MIN_GROUP_SIZE} and at most #{HIGHEST_MIN_GROUP_SIZE}"
  }
  validates :snapshot_every_months, inclusion: { in: SNAPSHOT_INTERVALS, message: "must be 1, 3 or 6" }

  # The 1st of the month the next snapshot is due on, counted from the month
  # of the last one, so a change of interval applies from the next 1st.
  #
  # @param last_taken_on [Date, nil]
  # @param today [Date] the tenant's today
  # @return [Date] today when none has been taken yet
  def next_snapshot_on(last_taken_on, today:)
    return today unless last_taken_on

    last_taken_on.beginning_of_month >> snapshot_every_months
  end
end

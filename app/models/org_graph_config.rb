# frozen_string_literal: true

# A tenant's Org Graph settings, stored in Tenant.org_graph_config JSONB.
#
# @example
#   tenant.org_graph_config.staleness_days # => 90
class OrgGraphConfig
  include StoreModel::Model

  # A quarter: long enough that a steady team isn't nagged, short enough that
  # a team that quietly changed shape is asked about within a planning cycle.
  DEFAULT_STALENESS_DAYS = 90
  MAX_STALENESS_DAYS = 3650

  # The design's default for how long a leaver's identifiers are kept.
  DEFAULT_RETENTION_YEARS = 7
  MAX_RETENTION_YEARS = 100

  # How long a fact Espalia holds may go without a change or a confirmation
  # before it is stale.
  attribute :staleness_days, :integer, default: DEFAULT_STALENESS_DAYS

  # How many years after a person leaves their identifiers are forgotten.
  # Nil keeps them for ever.
  attribute :retention_years, :integer, default: DEFAULT_RETENTION_YEARS

  validates :staleness_days, numericality: { only_integer: true, greater_than: 0,
                                             less_than_or_equal_to: MAX_STALENESS_DAYS }
  validates :retention_years, numericality: { only_integer: true, greater_than: 0,
                                              less_than_or_equal_to: MAX_RETENTION_YEARS }, allow_nil: true

  # @param now [Time]
  # @return [Time] a fact last changed or confirmed before this is stale
  def stale_before(now = Time.current)
    now - staleness_days.days
  end

  # @param on [Date]
  # @return [Date, nil] a person who left on or before this is due to be
  #   forgotten, or nil when the tenant keeps leavers for ever
  def forget_left_on_or_before(on = Date.current)
    on - retention_years.years if retention_years
  end
end

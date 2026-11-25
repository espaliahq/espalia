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

  # How long a fact Espalia holds may go without a change or a confirmation
  # before it is stale.
  attribute :staleness_days, :integer, default: DEFAULT_STALENESS_DAYS

  validates :staleness_days, numericality: { only_integer: true, greater_than: 0,
                                             less_than_or_equal_to: MAX_STALENESS_DAYS }

  # @param now [Time]
  # @return [Time] a fact last changed or confirmed before this is stale
  def stale_before(now = Time.current)
    now - staleness_days.days
  end
end

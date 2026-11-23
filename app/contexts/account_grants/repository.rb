# frozen_string_literal: true

# Loads and saves a tenant's account grants, held in one stream per tenant.
#
# @example
#   AccountGrants::Repository.new.with_grants { |grants| grants.add(:team_planner, ...) }
class AccountGrants::Repository < TenantStreams::Repository
  alias with_grants with_aggregate
  alias load_grants load_aggregate

  private

  def new_aggregate = AccountGrants::Aggregate.new

  def stream_name(tenant) = EventStreamNaming.account_grants_stream(tenant:)
end

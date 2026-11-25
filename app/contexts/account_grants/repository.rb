# frozen_string_literal: true

# Loads and saves a tenant's account grants, held in one stream per tenant:
# `TenantAccountGrants`.
#
# The grants used to live in `AccountGrants`. The release before this one
# writes the new stream and links its grants back into the old one, which it
# reads without the lock; this one links nothing back. So while it still
# serves, its unlocked read misses a grant this release writes until it
# next writes itself. The lock keeps the old stream's name, as that release
# takes it, and anything only the old stream holds is linked in before
# loading.
#
# @example
#   AccountGrants::Repository.new.with_grants { |grants| grants.add(:team_planner, ...) }
class AccountGrants::Repository < TenantStreams::Repository
  alias with_grants with_aggregate
  alias load_grants load_aggregate

  private

  def new_aggregate = AccountGrants::Aggregate.new

  def stream_name(tenant) = EventStreamNaming.tenant_account_grants_stream(tenant:)

  def legacy_stream_name(tenant) = EventStreamNaming.account_grants_stream(tenant:)

  def lock_key(tenant) = legacy_stream_name(tenant)

  def lock_stream(tenant)
    super
    link_missing(from: legacy_stream_name(tenant), to: stream_name(tenant))
  end

  def link_missing(from:, to:)
    linked = @event_store.read.stream(to).map(&:event_id).to_set
    missing = @event_store.read.stream(from).map(&:event_id).reject { linked.include?(it) }
    @event_store.link(missing, stream_name: to) if missing.any?
  end
end

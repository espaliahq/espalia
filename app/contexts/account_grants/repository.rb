# frozen_string_literal: true

# Loads and saves a tenant's account grants, held in one stream per tenant:
# `TenantAccountGrants`.
#
# The grants used to live in `AccountGrants`. A release before this stream
# may still write there during a deploy, so the lock keeps the old stream's
# name and, under it, events only in the old stream are linked into the new
# one before loading. Nothing is linked back, so the old stream stops at the
# events written before this release. A read without the lock reads the new
# stream, and misses an event the previous release wrote until the next
# command or reconcile links it.
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

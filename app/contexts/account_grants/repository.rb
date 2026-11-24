# frozen_string_literal: true

# Loads and saves a tenant's account grants, held in one stream per tenant:
# `TenantAccountGrants`.
#
# The grants used to live in `AccountGrants`, and a release still serving
# during a deploy writes there. Until that can't happen, the two streams are
# kept equal by linking: an event is recorded once and indexed in both. The
# lock keeps the old stream's name, so both releases take the same lock.
# Under it, events only in the old stream are linked into the new one before
# loading, and events appended to the new one are linked back. Track B of
# #539 stops the linking back.
#
# @example
#   AccountGrants::Repository.new.with_grants { |grants| grants.add(:team_planner, ...) }
class AccountGrants::Repository < TenantStreams::Repository
  # @see TenantStreams::Repository#with_aggregate
  def with_aggregate(&block)
    ActiveRecord::Base.transaction do
      super.tap { link_missing(from: stream_name(current_tenant!), to: legacy_stream_name(current_tenant!)) }
    end
  end

  # Reads the old stream, which holds every grant whichever release wrote it.
  #
  # @return [AccountGrants::Aggregate]
  def load_aggregate
    @repository.load(new_aggregate, legacy_stream_name(current_tenant!))
  end

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

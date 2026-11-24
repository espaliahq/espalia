# frozen_string_literal: true

# Event-sourced aggregate for the grants an admin gives a member's account.
#
# One RES stream per tenant: tenant-{tenant_id}/TenantAccountGrants. It holds who
# is an Org Graph editor and who is a planner. Holders are keyed by account
# (tenant_user_id), not person: a destroyed account's person can come back
# with a new account, which starts without the old one's grants.
#
# Adding a grant someone holds, or removing one they don't, writes nothing.
#
class AccountGrants::Aggregate
  include Shreddable::AggregateRoot

  EVENTS = {
    org_graph_editor: { added: AccountGrants::Events::OrgGraphEditorAdded, removed: AccountGrants::Events::OrgGraphEditorRemoved },
    team_planner: { added: AccountGrants::Events::PlannerAdded, removed: AccountGrants::Events::PlannerRemoved }
  }.freeze

  # The grants, named as the tenant_users columns that hold them.
  GRANTS = EVENTS.keys.freeze

  # What the addition that gave a held grant recorded: when it took effect,
  # who gave it, and whether it was held before grants were events.
  Holding = Data.define(:person_id, :since, :added_by_id, :already_held)

  def initialize
    @holdings = GRANTS.index_with { {} }
  end

  # @param grant [Symbol] one of {GRANTS}
  # @param tenant_user_id [String]
  # @return [Boolean]
  def holds?(grant, tenant_user_id)
    holdings(grant).key?(tenant_user_id.to_s)
  end

  # @param grant [Symbol] one of {GRANTS}
  # @return [Hash{String => String, nil}] each holding account's id to its person's id
  def holders(grant)
    holdings(grant).transform_values(&:person_id)
  end

  # @param grant [Symbol] one of {GRANTS}
  # @return [Hash{String => Holding}] each holding account's id to how it came to hold the grant
  def holdings(grant)
    @holdings.fetch(grant)
  end

  # @param grant [Symbol] one of {GRANTS}
  # @param tenant_user_id [String]
  # @param person_id [String, nil]
  # @param effective_on [Date, String]
  # @param added_by_id [String, nil] person_id of the actor
  # @param already_held [Boolean] true when recording a grant held before it was an event
  # @raise [KeyError] for an unknown grant
  def add(grant, tenant_user_id:, person_id:, effective_on:, added_by_id: nil, already_held: false)
    added = EVENTS.fetch(grant).fetch(:added)
    return if holds?(grant, tenant_user_id)

    apply(added.new(data: {
      tenant_user_id: tenant_user_id.to_s, person_id: person_id, effective_on: effective_on.to_date.iso8601,
      added_by_id: added_by_id, already_held: already_held
    }))
  end

  # @param grant [Symbol] one of {GRANTS}
  # @param tenant_user_id [String]
  # @param person_id [String, nil]
  # @param effective_on [Date, String]
  # @param removed_by_id [String, nil] person_id of the actor
  # @raise [KeyError] for an unknown grant
  def remove(grant, tenant_user_id:, person_id:, effective_on:, removed_by_id: nil)
    removed = EVENTS.fetch(grant).fetch(:removed)
    return unless holds?(grant, tenant_user_id)

    apply(removed.new(data: {
      tenant_user_id: tenant_user_id.to_s, person_id: person_id, effective_on: effective_on.to_date.iso8601,
      removed_by_id: removed_by_id
    }))
  end

  EVENTS.each do |grant, events|
    on(events.fetch(:added)) do |event|
      data = event.data
      @holdings[grant][data[:tenant_user_id]] = Holding.new(
        person_id: data[:person_id], since: Date.iso8601(data[:effective_on]),
        added_by_id: data[:added_by_id], already_held: data[:already_held] == true
      )
    end
    on(events.fetch(:removed)) { |event| @holdings[grant].delete(event.data[:tenant_user_id]) }
  end
end

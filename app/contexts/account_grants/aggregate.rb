# frozen_string_literal: true

# Event-sourced aggregate for the grants an admin gives a member's account.
#
# One RES stream per tenant: tenant-{tenant_id}/TenantAccountGrants. It holds who
# is an Org Graph editor, who is a planner, and each account's role. Holders are keyed by account
# (tenant_user_id), not person: a destroyed account's person can come back
# with a new account, which starts without the old one's grants.
#
# Adding a grant someone holds, or removing one they don't, writes nothing,
# and so does setting a role an account already has. The tenant always keeps
# an admin, so demoting the last one is refused.
#
# It also reads the person each account is linked to, though no command here
# writes a link yet: a release loads those events before any release writes them.
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

  # An account's roles, named as TenantUser's.
  ROLES = TenantUser::ROLES.values.freeze

  # Raised when a command would leave the tenant with no admin.
  class LastAdmin < StandardError; end

  def initialize
    @holdings = GRANTS.index_with { {} }
    @roles = {}
    @links = {}
  end

  # @return [Hash{String => String}] each account's id to its role
  def roles
    @roles.transform_values(&:first)
  end

  # @return [Hash{String => String, nil}] each account with a role to its person's id when the role was set
  def role_holders
    @roles.transform_values(&:last)
  end

  # @param tenant_user_id [String]
  # @return [String, nil] the account's role, nil when none is recorded
  def role_of(tenant_user_id)
    @roles[tenant_user_id.to_s]&.first
  end

  # @return [Hash{String => String}] each linked account's id to its person's id
  def links
    @links.dup
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

  # Recording a role held before roles were events skips the last-admin
  # check, since the table it comes from is the truth.
  #
  # @param tenant_user_id [String]
  # @param person_id [String, nil]
  # @param role [String, Symbol] one of {ROLES}
  # @param effective_on [Date, String]
  # @param set_by_id [String, nil] person_id of the actor
  # @param already_held [Boolean] true when recording a role held before it was an event
  # @raise [ArgumentError] for an unknown role
  # @raise [LastAdmin] when it would demote the tenant's last admin
  def set_role(tenant_user_id:, person_id:, role:, effective_on:, set_by_id: nil, already_held: false)
    role = role.to_s
    raise ArgumentError, "unknown role: #{role}" unless ROLES.include?(role)

    id = tenant_user_id.to_s
    return if role_of(id) == role
    raise LastAdmin, "the organisation must keep an admin" if !already_held && last_admin?(id)

    apply(AccountGrants::Events::AccountRoleSet.new(data: {
      tenant_user_id: id, person_id: person_id, role: role, effective_on: effective_on.to_date.iso8601,
      set_by_id: set_by_id, already_held: already_held
    }))
  end

  # @param tenant_user_id [String] an account destroyed or forgotten since its role was set
  # @param person_id [String, nil]
  # @param effective_on [Date, String]
  # @param removed_by_id [String, nil] person_id of the actor, nil when reconcile records it
  def remove_role(tenant_user_id:, person_id:, effective_on:, removed_by_id: nil)
    id = tenant_user_id.to_s
    return unless @roles.key?(id)

    apply(AccountGrants::Events::AccountRoleRemoved.new(data: {
      tenant_user_id: id, person_id: person_id, effective_on: effective_on.to_date.iso8601,
      removed_by_id: removed_by_id
    }))
  end

  on(AccountGrants::Events::AccountRoleSet) do |event|
    @roles[event.data[:tenant_user_id]] = event.data.values_at(:role, :person_id)
  end
  on(AccountGrants::Events::AccountRoleRemoved) { |event| @roles.delete(event.data[:tenant_user_id]) }

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

  on(AccountGrants::Events::AccountLinkedToPerson) do |event|
    @links[event.data[:tenant_user_id]] = event.data[:person_id]
  end
  on(AccountGrants::Events::AccountUnlinkedFromPerson) { |event| @links.delete(event.data[:tenant_user_id]) }

  private

  def last_admin?(tenant_user_id)
    role_of(tenant_user_id) == "admin" && roles.count { |_, role| role == "admin" } == 1
  end
end

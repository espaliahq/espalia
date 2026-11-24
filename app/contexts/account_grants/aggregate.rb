# frozen_string_literal: true

# Event-sourced aggregate for the grants an admin gives a member's account.
#
# One RES stream per tenant: tenant-{tenant_id}/TenantAccountGrants. It holds who
# is an Org Graph editor, who is a planner, and each account's role. Holders are keyed by account
# (tenant_user_id), not person: a destroyed account's person can come back
# with a new account, which starts without the old one's grants.
#
# Adding a grant someone holds, or removing one they don't, writes nothing,
# and so does setting a role an account already has or a link it holds. The
# tenant always keeps an admin, so demoting the last one is refused.
#
# It also records the person each account is linked to. An account links to
# one person, a person to one account, and nobody links to a forgotten
# person. Links held before they were events are recorded as they stand,
# even two accounts sharing a person, so an admin can decide.
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

  # Why an account was unlinked: its person was forgotten, an admin unlinked
  # it, its row was destroyed, or reconcile found the link cleared.
  UNLINK_REASONS = %w[forgotten admin account_removed cleared].freeze

  # How a link's person was found.
  MATCHES = %w[sign_in hris_email provisioned admin].freeze

  # Raised when a command would leave the tenant with no admin.
  class LastAdmin < StandardError; end

  # Raised when a link is refused, for either reason below.
  class LinkRefused < StandardError; end

  # Raised when a link would break the one-account, one-person rule.
  class LinkTaken < LinkRefused; end

  # Raised when a link names a forgotten person.
  class PersonForgotten < LinkRefused; end

  def initialize
    @holdings = GRANTS.index_with { {} }
    @roles = {}
    @links = {}
    @forgotten = Set.new
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

  # @param tenant_user_id [String]
  # @return [String, nil] the person the account is linked to
  def person_of(tenant_user_id)
    @links[tenant_user_id.to_s]
  end

  # @param person_id [String]
  # @return [Array<String>] the accounts linked to the person; more than one only for links recorded as held
  def accounts_of(person_id)
    @links.filter_map { |id, linked| id if linked == person_id.to_s }
  end

  # @return [Hash{String => Array<String>}] each person linked to more than one account, to those accounts
  def shared_people
    @links.group_by(&:last).filter_map { |person, pairs| [ person, pairs.map(&:first) ] if pairs.size > 1 }.to_h
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

  # Recording a link held before links were events skips the rules, since the
  # table it comes from is the truth.
  #
  # @param tenant_user_id [String]
  # @param person_id [String]
  # @param effective_on [Date, String]
  # @param linked_by_id [String, nil] person_id of the actor
  # @param match [String, nil] one of {MATCHES}, nil when recorded as held
  # @param already_held [Boolean] true when recording a link made before links were events
  # @raise [ArgumentError] for an unknown match
  # @raise [LinkTaken] when the account or the person is linked elsewhere
  # @raise [PersonForgotten] when the person was forgotten
  def link_account(tenant_user_id:, person_id:, effective_on:, linked_by_id: nil, match: nil, already_held: false)
    raise ArgumentError, "unknown match: #{match}" unless match.nil? || MATCHES.include?(match.to_s)

    id = tenant_user_id.to_s
    person_id = person_id.to_s
    return if person_of(id) == person_id

    unless already_held
      raise PersonForgotten, "a forgotten person can't be linked" if @forgotten.include?(person_id)
      raise LinkTaken, "the account is linked to another person" if person_of(id)
      raise LinkTaken, "the person is linked to another account" if accounts_of(person_id).any?
    end

    apply(AccountGrants::Events::AccountLinkedToPerson.new(data: {
      tenant_user_id: id, person_id: person_id, effective_on: effective_on.to_date.iso8601,
      linked_by_id: linked_by_id, match: match&.to_s, already_held: already_held
    }))
  end

  # @param tenant_user_id [String]
  # @param effective_on [Date, String]
  # @param reason [String, Symbol] one of {UNLINK_REASONS}
  # @param unlinked_by_id [String, nil] person_id of the actor, nil when none
  # @raise [ArgumentError] for an unknown reason
  def unlink_account(tenant_user_id:, effective_on:, reason:, unlinked_by_id: nil)
    reason = reason.to_s
    raise ArgumentError, "unknown reason: #{reason}" unless UNLINK_REASONS.include?(reason)

    id = tenant_user_id.to_s
    person_id = person_of(id)
    return unless person_id

    apply(AccountGrants::Events::AccountUnlinkedFromPerson.new(data: {
      tenant_user_id: id, person_id: person_id, effective_on: effective_on.to_date.iso8601,
      unlinked_by_id: unlinked_by_id, reason: reason
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
  on(AccountGrants::Events::AccountUnlinkedFromPerson) do |event|
    @links.delete(event.data[:tenant_user_id])
    @forgotten << event.data[:person_id] if event.data[:reason] == "forgotten"
  end

  private

  def last_admin?(tenant_user_id)
    role_of(tenant_user_id) == "admin" && roles.count { |_, role| role == "admin" } == 1
  end
end

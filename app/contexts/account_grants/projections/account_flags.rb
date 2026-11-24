# frozen_string_literal: true

# Synchronous projection of the grant, role and link columns of
# `tenant_users` from the TenantAccountGrants stream: `org_graph_editor`,
# `team_planner`, `role` and `person_id`.
#
# The only writer of those columns once a row exists, and of nothing else on
# the row. A forgotten account sits outside TenantUser's default scope, so
# neither a live event nor a rebuild touches its flags.
#
class AccountGrants::Projections::AccountFlags
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "account_grants/account_flags"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 2

  COLUMNS = (AccountGrants::Aggregate::GRANTS.map(&:to_s) + %w[role person_id]).freeze

  FLAGS = AccountGrants::Aggregate::EVENTS.flat_map do |grant, events|
    [ [ events.fetch(:added), [ grant, true ] ], [ events.fetch(:removed), [ grant, false ] ] ]
  end.to_h.freeze
  private_constant :FLAGS

  LINK_EVENTS = [ AccountGrants::Events::AccountLinkedToPerson, AccountGrants::Events::AccountUnlinkedFromPerson ].freeze
  private_constant :LINK_EVENTS

  RESET = <<~SQL.squish.freeze
    org_graph_editor = COALESCE(id IN (:org_graph_editor), false),
    team_planner = COALESCE(id IN (:team_planner), false),
    role = CASE WHEN id IN (:admin) THEN 'admin' WHEN id IN (:member) THEN 'member' ELSE role END,
    person_id = COALESCE((SELECT people.id FROM people WHERE people.id = CAST(CAST(:links AS jsonb) ->> CAST(tenant_users.id AS text) AS uuid)), person_id)
  SQL
  private_constant :RESET

  # @return [Array<Class>]
  def self.handled_events
    FLAGS.keys + [ AccountGrants::Events::AccountRoleSet ] + LINK_EVENTS
  end

  # Sets both grants, the role and the link on every live account of the
  # tenant to what the stream holds, in one statement. A link the stream
  # doesn't hold is kept: the previous release may have written it since the
  # last reconcile, which records it next. So is the column when the stream's
  # person was destroyed, which nullifies the link without an event. A reset that clears them would
  # leave a rebuild that stops before its replay with every flag clear, and the next
  # deploy's reconcile would record each grant as removed. It holds the
  # stream's lock, so a grant a command writes meanwhile can't be overwritten.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      AccountGrants::Repository.new.reading_locked do |grants|
        holders = AccountGrants::Aggregate::GRANTS.to_h { [ it, grants.holders(it).keys ] }
        holders.merge!(grants.roles.group_by(&:last).to_h { |role, pairs| [ role.to_sym, pairs.map(&:first) ] })
        values = (AccountGrants::Aggregate::GRANTS + %i[admin member]).to_h { [ it, holders[it].presence || [ nil ] ] }
        values[:links] = grants.links.to_json
        TenantUser.where(tenant_id: tenant.id).update_all([ RESET, values ])
      end
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    # The reset already wrote where the stream ends. Replaying its events
    # again would pass through earlier states a stopped replay could leave.
    return if Projections::Replayer.replay_mode?

    tenant = ActsAsTenant.current_tenant
    tenant = Tenant.find(event.metadata[:tenant_id]) unless tenant&.id == event.metadata[:tenant_id]

    ActsAsTenant.with_tenant(tenant) { write(event) }
  end

  private

  def write(event)
    account = TenantUser.where(id: event.data[:tenant_user_id])
    case event
    when AccountGrants::Events::AccountLinkedToPerson
      account = account.where(person_id: nil).or(account.where.not(person_id: event.data[:person_id]))
      account.update_all(person_id: event.data[:person_id], updated_at: Time.current)
    when AccountGrants::Events::AccountUnlinkedFromPerson
      account.where(person_id: event.data[:person_id]).update_all(person_id: nil, updated_at: Time.current)
    else
      column, value = event.is_a?(AccountGrants::Events::AccountRoleSet) ? [ :role, event.data[:role] ] : FLAGS.fetch(event.class)
      account.where.not(column => value).update_all(column => value, updated_at: Time.current)
    end
  end
end

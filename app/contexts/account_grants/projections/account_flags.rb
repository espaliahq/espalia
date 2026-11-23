# frozen_string_literal: true

# Synchronous projection of the grant columns of `tenant_users` from the
# AccountGrants stream: `org_graph_editor` and `team_planner`.
#
# The only writer of those two columns, and of nothing else on the row. A
# forgotten account sits outside TenantUser's default scope, so neither a
# live event nor a rebuild touches its flags.
#
class AccountGrants::Projections::AccountFlags
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "account_grants/account_flags"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  COLUMNS = AccountGrants::Aggregate::GRANTS.map(&:to_s).freeze

  FLAGS = AccountGrants::Aggregate::EVENTS.flat_map do |grant, events|
    [ [ events.fetch(:added), [ grant, true ] ], [ events.fetch(:removed), [ grant, false ] ] ]
  end.to_h.freeze
  private_constant :FLAGS

  # @return [Array<Class>]
  def self.handled_events
    FLAGS.keys
  end

  # Clears both grants on every live account of the tenant.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      TenantUser.where(tenant_id: tenant.id).update_all(COLUMNS.index_with(false))
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    column, value = FLAGS.fetch(event.class)
    tenant = ActsAsTenant.current_tenant
    tenant = Tenant.find(event.metadata[:tenant_id]) unless tenant&.id == event.metadata[:tenant_id]

    ActsAsTenant.with_tenant(tenant) do
      TenantUser.where(id: event.data[:tenant_user_id]).update_all(column => value, updated_at: Time.current)
    end
  end
end

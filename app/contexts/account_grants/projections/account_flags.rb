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

  # Sets both grants on every live account of the tenant to what the stream
  # holds, in one statement. A reset that clears them instead would leave a
  # rebuild that stops before its replay with every flag clear, and the next
  # deploy's reconcile would record each grant as removed. It holds the
  # stream's lock, so a grant written meanwhile can't be overwritten.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      AccountGrants::Repository.new.reading_locked do |grants|
        sets = COLUMNS.map { |column| "#{column} = COALESCE(id IN (:#{column}), false)" }.join(", ")
        holders = AccountGrants::Aggregate::GRANTS.to_h { [ it, grants.holders(it).keys.presence || [ nil ] ] }
        TenantUser.where(tenant_id: tenant.id).update_all([ sets, holders ])
      end
    end
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    # The reset already wrote where the stream ends. Replaying its events
    # again would pass through earlier states a stopped replay could leave.
    return if Projections::Replayer.replay_mode?

    column, value = FLAGS.fetch(event.class)
    tenant = ActsAsTenant.current_tenant
    tenant = Tenant.find(event.metadata[:tenant_id]) unless tenant&.id == event.metadata[:tenant_id]

    ActsAsTenant.with_tenant(tenant) do
      TenantUser.where(id: event.data[:tenant_user_id]).update_all(column => value, updated_at: Time.current)
    end
  end
end

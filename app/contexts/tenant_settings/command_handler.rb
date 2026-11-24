# frozen_string_literal: true

# Handles commands for a tenant's retention period and scheduled forgetting.
#
# Until [#539](https://github.com/espaliahq/espalia/issues/539) Track C's c2,
# each command also writes the old keys of `tenants.org_graph_config`, which
# the previous release reads and writes while a deploy is in flight. Under
# the stream's lock and then the tenant row's, it first records what those
# keys hold, then changes both in one transaction.
#
class TenantSettings::CommandHandler
  # What setting the period did.
  RetentionResult = Data.define(:retention_years, :scheduled_forgetting_stopped)

  # @param tenant [Tenant]
  # @param repository [TenantSettings::Repository]
  def initialize(tenant, repository: TenantSettings::Repository.new)
    @tenant = tenant
    @repository = repository
  end

  # @param years [Integer, nil] nil for never
  # @param set_by [TenantUser, nil] the admin
  # @return [RetentionResult]
  def set_retention_period(years, set_by: nil)
    stopped = false
    change do |settings|
      stopped = settings.set_retention_period(years, set_by_id: set_by&.person_id)
    end
    RetentionResult.new(retention_years: years, scheduled_forgetting_stopped: stopped)
  end

  # Turns scheduled forgetting on. The block runs under both locks and
  # returns the count the admin confirmed, or raises to refuse.
  #
  # @param enabled_by [TenantUser, nil] the admin
  # @yieldparam settings [TenantSettings::Aggregate] as they stand, the JSON's settled in
  # @yieldreturn [Integer] the confirmed count
  # @return [Integer] the confirmed count
  # @raise [TenantSettings::Aggregate::Refused]
  def enable_scheduled_forgetting(enabled_by: nil)
    count = nil
    change(enabled_by_account_id: enabled_by&.id) do |settings|
      raise TenantSettings::Aggregate::Refused, "retention is set to never, so there is nothing to schedule" if
        settings.retention_years.nil?

      count = yield settings
      settings.enable(enabled_by_id: enabled_by&.person_id, confirmed_count: count) unless settings.scheduled_forgetting?
    end
    count
  end

  # @param disabled_by [TenantUser, nil] the admin
  # @return [void]
  def disable_scheduled_forgetting(disabled_by: nil)
    change { |settings| settings.disable(disabled_by_id: disabled_by&.person_id) }
  end

  private

  # Settles, then changes, in one transaction, so both locks hold from the
  # first read to the commit. The settled events are stored before the
  # command's block runs, so what it reads of the projection is settled too.
  def change(enabled_by_account_id: nil)
    ActsAsTenant.with_tenant(@tenant) do
      ActiveRecord::Base.transaction do
        @repository.with_settings { |settings| @tenant.with_lock { settle(settings, @tenant.org_graph_config) } }
        @repository.with_settings do |settings|
          @tenant.with_lock do
            was_on = settings.scheduled_forgetting?
            yield settings
            write_json(settings, @tenant.org_graph_config.dup, was_on, enabled_by_account_id)
          end
        end
      end
    end
  end

  # The previous release, still serving during a deploy, writes the JSON
  # only. Record what it holds first, as reconcile would, so the command
  # acts on the settings the tenant has rather than a stale stream.
  def settle(settings, config)
    settings.record_held(
      retention_years: config.retention_years, scheduled_forgetting: config.scheduled_forgetting,
      enabled_at: config.scheduled_forgetting_enabled_at,
      enabled_by_id: TenantUser.unscoped.where(id: config.scheduled_forgetting_enabled_by_id).pick(:person_id)
    )
  end

  # The JSON names the admin by account, where the stream names their person.
  def write_json(settings, config, was_on, enabled_by_account_id)
    on = settings.scheduled_forgetting?
    config.retention_years = settings.retention_years
    config.scheduled_forgetting = on
    config.scheduled_forgetting_enabled_at = settings.enabled_at
    config.scheduled_forgetting_enabled_by_id = nil unless on
    config.scheduled_forgetting_enabled_by_id = enabled_by_account_id if on && !was_on
    @tenant.update!(org_graph_config: config)
  end
end

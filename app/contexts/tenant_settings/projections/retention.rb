# frozen_string_literal: true

# Synchronous projection of `tenant_retention_settings` from the
# TenantSettings stream: one row per tenant that has recorded any setting.
#
# The only writer of that table.
#
class TenantSettings::Projections::Retention
  # Stable identifier used as the natural key in `projection_versions.name`.
  PROJECTION_NAME = "tenant_settings/retention"

  # Bump when `reset!` or any handler would write different state from the
  # same event payload than before.
  CODE_VERSION = 1

  # @return [Array<Class>]
  def self.handled_events
    [
      TenantSettings::Events::RetentionPeriodSet,
      TenantSettings::Events::ScheduledForgettingEnabled,
      TenantSettings::Events::ScheduledForgettingDisabled
    ]
  end

  # Writes the row from where the stream ends, or removes it when the stream
  # holds nothing. A reset that only cleared the row would leave a rebuild
  # that stops before its replay reading as the defaults: scheduled
  # forgetting off for every tenant. It holds the stream's lock, so a
  # setting a command writes meanwhile can't be overwritten.
  #
  # @param tenant [Tenant]
  def self.reset!(tenant:)
    ActsAsTenant.with_tenant(tenant) do
      TenantSettings::Repository.new.reading_locked do |settings|
        next TenantRetentionSetting.where(tenant:).delete_all unless settings.recorded?

        write(tenant, retention_years: settings.retention_years, scheduled_forgetting: settings.scheduled_forgetting?,
                      enabled_at: settings.enabled_at, enabled_by_id: settings.enabled_by_id)
      end
    end
  end

  # @param tenant [Tenant]
  # @param attributes [Hash] the columns to set; the rest start at the defaults
  def self.write(tenant, **attributes)
    row = TenantRetentionSetting.for(tenant)
    row.assign_attributes(attributes)
    row.save!
  end

  # @param event [RubyEventStore::Event]
  def call(event)
    # The reset already wrote where the stream ends. Replaying its events
    # again would pass through earlier states a stopped replay could leave.
    return if Projections::Replayer.replay_mode?

    tenant = ActsAsTenant.current_tenant
    tenant = Tenant.find(event.metadata[:tenant_id]) unless tenant&.id == event.metadata[:tenant_id]
    ActsAsTenant.with_tenant(tenant) { self.class.write(tenant, **columns(event)) }
  end

  private

  def columns(event)
    data = event.data
    case event
    when TenantSettings::Events::RetentionPeriodSet then { retention_years: data[:retention_years] }
    when TenantSettings::Events::ScheduledForgettingEnabled
      { scheduled_forgetting: true, enabled_at: Time.iso8601(data[:enabled_at]), enabled_by_id: data[:enabled_by_id] }
    else { scheduled_forgetting: false, enabled_at: nil, enabled_by_id: nil }
    end
  end
end

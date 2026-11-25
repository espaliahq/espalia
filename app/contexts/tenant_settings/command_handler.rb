# frozen_string_literal: true

# Handles commands for a tenant's retention period and scheduled forgetting.
#
# Each command also removes the retired retention keys from
# `tenants.org_graph_config`, under the stream's lock and then the tenant
# row's, in one transaction. The previous release writes them back while a
# deploy is in flight, and its predeploy would record what they hold over
# the stream if it were deployed again.
#
class TenantSettings::CommandHandler
  # The keys the stream replaced.
  RETIRED_KEYS = %w[retention_years scheduled_forgetting scheduled_forgetting_enabled_at
                    scheduled_forgetting_enabled_by_id].freeze

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
  # @yieldparam settings [TenantSettings::Aggregate] as they stand
  # @yieldreturn [Integer] the confirmed count
  # @return [Integer] the confirmed count
  # @raise [TenantSettings::Aggregate::Refused]
  def enable_scheduled_forgetting(enabled_by: nil)
    count = nil
    change do |settings|
      raise TenantSettings::Aggregate::Refused, "retention is set to never, so there is nothing to schedule" if
        settings.retention_years.nil?
      raise TenantSettings::Aggregate::Refused, "scheduled forgetting is already on" if settings.scheduled_forgetting?

      count = yield settings
      settings.enable(enabled_by_id: enabled_by&.person_id, confirmed_count: count)
    end
    count
  end

  # @param disabled_by [TenantUser, nil] the admin
  # @return [void]
  def disable_scheduled_forgetting(disabled_by: nil)
    change { |settings| settings.disable(disabled_by_id: disabled_by&.person_id) }
  end

  private

  def change
    ActsAsTenant.with_tenant(@tenant) do
      ActiveRecord::Base.transaction do
        @repository.with_settings do |settings|
          @tenant.with_lock do
            yield settings
            remove_retired_keys
          end
        end
      end
    end
  end

  def remove_retired_keys
    Tenant.where(id: @tenant.id)
          .update_all([ "org_graph_config = org_graph_config - ARRAY[?]::text[]", RETIRED_KEYS ])
  end
end

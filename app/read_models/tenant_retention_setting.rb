# frozen_string_literal: true

# A tenant's retention period and whether leavers are forgotten on a
# schedule. A tenant with no row has never changed either: seven years, off.
#
# Projected from the TenantSettings stream by
# {TenantSettings::Projections::Retention}, and nothing else writes it.
#
# Until [#539](https://github.com/espaliahq/espalia/issues/539) Track C's c2,
# `tenants.org_graph_config` holds the same settings, and the previous
# release may still write only there. So forgetting asks both: a tenant is
# scheduled only when both say so, and the longer period of the two decides
# who is due. The id derives from the tenant, so a rebuild keeps it.
class TenantRetentionSetting < ApplicationRecord
  include DeterministicId
  deterministic_id_from :tenant_id

  acts_as_tenant :tenant

  belongs_to :tenant
  # Optional, and a person id, so a forgotten admin reads as a former member.
  belongs_to :enabled_by, class_name: "Person", optional: true

  # @param tenant [Tenant]
  # @return [TenantRetentionSetting] the tenant's row, or an unsaved one at the defaults
  def self.for(tenant)
    unscoped.find_by(tenant_id: tenant.id) || new(tenant:, retention_years: OrgGraphConfig::DEFAULT_RETENTION_YEARS, scheduled_forgetting: false)
  end

  # @return [ActiveRecord::Relation<Tenant>] the tenants both places say forget on a schedule
  def self.scheduled_tenants
    Tenant.where("(org_graph_config->>'scheduled_forgetting')::boolean")
      .where(id: unscoped.where(scheduled_forgetting: true).select(:tenant_id))
  end

  # @param tenant [Tenant]
  # @param config [OrgGraphConfig] the tenant's JSON, read under whatever lock the caller holds
  # @return [Boolean] whether both places say forget on a schedule
  def self.scheduled?(tenant, config: tenant.org_graph_config)
    config.scheduled_forgetting && self.for(tenant).scheduled_forgetting
  end

  # @param tenant [Tenant]
  # @param config [OrgGraphConfig] the tenant's JSON, read under whatever lock the caller holds
  # @return [Integer, nil] the longer of the two periods; nil when either keeps leavers for ever
  def self.longer_period(tenant, config: tenant.org_graph_config)
    periods = [ config.retention_years, self.for(tenant).retention_years ]
    periods.max unless periods.include?(nil)
  end

  # @param tenant [Tenant]
  # @param on [Date]
  # @param config [OrgGraphConfig] the tenant's JSON, read under whatever lock the caller holds
  # @return [Date, nil] who left on or before this is due, by the longer period; nil when nobody is
  def self.forget_left_on_or_before(tenant, on = tenant.today, config: tenant.org_graph_config)
    years = longer_period(tenant, config:)
    on - years.years if years
  end
end

# frozen_string_literal: true

# A tenant's retention period and whether leavers are forgotten on a
# schedule. A tenant with no row has never changed either: seven years, off.
#
# Projected from the TenantSettings stream by
# {TenantSettings::Projections::Retention}, and nothing else writes it. The
# id derives from the tenant, so a rebuild keeps it.
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
    unscoped.find_by(tenant_id: tenant.id) || new(tenant:, retention_years: TenantSettings::Aggregate::DEFAULT_RETENTION_YEARS, scheduled_forgetting: false)
  end

  # @return [ActiveRecord::Relation<Tenant>] the tenants whose leavers are forgotten on a schedule
  def self.scheduled_tenants
    Tenant.where(id: unscoped.where(scheduled_forgetting: true).select(:tenant_id))
  end

  # @param tenant [Tenant]
  # @return [Boolean] whether the tenant's leavers are forgotten on a schedule
  def self.scheduled?(tenant) = self.for(tenant).scheduled_forgetting

  # @param tenant [Tenant]
  # @return [Integer, nil] years after leaving that a person is forgotten; nil keeps them for ever
  def self.period(tenant) = self.for(tenant).retention_years

  # @param tenant [Tenant]
  # @param on [Date]
  # @return [Date, nil] who left on or before this is due; nil when nobody is
  def self.forget_left_on_or_before(tenant, on = tenant.today)
    years = period(tenant)
    on - years.years if years
  end
end

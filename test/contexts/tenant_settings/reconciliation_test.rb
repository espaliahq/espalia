# frozen_string_literal: true

require "test_helper"

class TenantSettings::ReconciliationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :admin, person: create(:person, tenant: @tenant)) }
  end

  def reconcile = TenantSettings::Reconciliation.new(Tenant.find(@tenant.id)).call
  def row = TenantRetentionSetting.unscoped.find_by(tenant_id: @tenant.id)
  def stream = Rails.configuration.event_store.read.stream(EventStreamNaming.tenant_settings_stream(tenant: @tenant)).to_a

  # The previous release, still serving during a deploy, writes the JSON alone.
  def previous_release_writes(**settings)
    Tenant.find(@tenant.id).tap { it.org_graph_config.assign_attributes(settings) }.save!
  end

  should "write nothing for a tenant still at the defaults" do
    assert_equal 0, reconcile.recorded
    assert_empty stream
    assert_nil row
  end

  should "record what the previous release wrote as already held, with no actor, and project it" do
    enabled_at = Time.utc(2026, 11, 2, 9)
    previous_release_writes(retention_years: 4, scheduled_forgetting: true,
                            scheduled_forgetting_enabled_at: enabled_at, scheduled_forgetting_enabled_by_id: @admin.id)

    assert_equal 1, reconcile.changed
    assert_equal [ TenantSettings::Events::RetentionPeriodSet, TenantSettings::Events::ScheduledForgettingEnabled ], stream.map(&:class)
    assert(stream.all? { it.data[:already_held] })
    assert_nil stream.first.data[:set_by_id]
    assert_equal [ 4, true, enabled_at, @admin.person_id ], row.slice(:retention_years, :scheduled_forgetting, :enabled_at, :enabled_by_id).values
  end

  should "write nothing when run again" do
    previous_release_writes(retention_years: 4)
    reconcile

    assert_equal 0, reconcile.recorded
    assert_equal 1, stream.size
  end

  should "record a schedule the previous release turned off" do
    TenantSettings::CommandHandler.new(Tenant.find(@tenant.id)).enable_scheduled_forgetting(enabled_by: @admin) { 0 }
    previous_release_writes(scheduled_forgetting: false, scheduled_forgetting_enabled_at: nil, scheduled_forgetting_enabled_by_id: nil)

    assert_equal 1, reconcile.changed
    assert_instance_of TenantSettings::Events::ScheduledForgettingDisabled, stream.last
    assert_nil stream.last.data[:reason]
    assert_not row.scheduled_forgetting
  end

  should "record a schedule the previous release turned off and on again as both" do
    TenantSettings::CommandHandler.new(Tenant.find(@tenant.id)).enable_scheduled_forgetting(enabled_by: @admin) { 0 }
    restarted_at = 1.hour.from_now.utc.change(usec: 0)
    previous_release_writes(scheduled_forgetting_enabled_at: restarted_at)

    assert_equal 1, reconcile.changed
    assert_equal [ TenantSettings::Events::ScheduledForgettingDisabled, TenantSettings::Events::ScheduledForgettingEnabled ],
                 stream.last(2).map(&:class)
    assert_equal restarted_at, row.enabled_at
  end

  should "record a schedule turned on with no time as already held once" do
    previous_release_writes(scheduled_forgetting: true)

    reconcile

    assert_equal 0, reconcile.recorded
    assert row.scheduled_forgetting
  end
end

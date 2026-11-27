# frozen_string_literal: true

require "test_helper"

class TenantSettingChangeTest < ActiveSupport::TestCase
  def history(tenant) = ActsAsTenant.with_tenant(tenant) { tenant.setting_changes.order(:changed_at, :id).pluck(:setting, :value) }

  def smallest_group(tenant, size)
    config = tenant.comparison_config.dup
    config.min_group_size = size
    tenant.update!(comparison_config: config)
  end

  context "a tenant's save" do
    should "record both settings when the tenant is created" do
      tenant = create(:tenant, time_zone: "Australia/Sydney")

      assert_equal [ %w[time_zone Australia/Sydney], %w[min_group_size 5] ], history(tenant)
    end

    should "record a change to either setting, and nothing for an unrelated save" do
      tenant = create(:tenant)

      tenant.update!(time_zone: "Europe/Paris")
      smallest_group(tenant, 7)
      tenant.update!(name: "Renamed")

      assert_equal [ %w[time_zone UTC], %w[min_group_size 5], %w[time_zone Europe/Paris], %w[min_group_size 7] ], history(tenant)
    end

    should "record nothing when the save rolls back" do
      tenant = create(:tenant)

      Tenant.transaction do
        tenant.update!(time_zone: "Europe/Paris")
        raise ActiveRecord::Rollback
      end

      assert_equal [ %w[time_zone UTC], %w[min_group_size 5] ], history(tenant)
    end
  end

  should "keep a row unchanged once saved" do
    row = ActsAsTenant.with_tenant(tenant = create(:tenant)) { tenant.setting_changes.first }

    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(value: "Europe/Paris") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy! }
  end

  context "the zone a past day ends in" do
    setup do
      travel_to Time.utc(2026, 3, 1, 12)
      @tenant = create(:tenant, time_zone: "UTC")
      travel_to Time.utc(2026, 4, 1, 12)
      @tenant.update!(time_zone: "Australia/Sydney")
    end

    should "be the zone in force at the end of that day" do
      assert_equal Time.utc(2026, 3, 15).end_of_day, @tenant.end_of_day_then(Date.new(2026, 3, 15))
      assert_equal Time.find_zone("Australia/Sydney").local(2026, 4, 15).end_of_day, @tenant.end_of_day_then(Date.new(2026, 4, 15))
    end

    should "be the first recorded zone for a day before the tenant's first row" do
      assert_equal Time.utc(2025, 12, 31).end_of_day, @tenant.end_of_day_then(Date.new(2025, 12, 31))
    end

    should "see a change made since the tenant was read, once it reloads" do
      Tenant.find(@tenant.id).update!(time_zone: "Europe/Paris")

      assert_equal Time.find_zone("Europe/Paris").local(2026, 4, 15).end_of_day, @tenant.reload.end_of_day_then(Date.new(2026, 4, 15))
    end
  end

  should "read today's zone for a tenant with no rows at all" do
    tenant = create(:tenant, time_zone: "Europe/Paris")
    TenantSettingChange.where(tenant_id: tenant.id).delete_all

    assert_equal Time.find_zone("Europe/Paris").local(2026, 3, 15).end_of_day, tenant.reload.end_of_day_then(Date.new(2026, 3, 15))
  end
end

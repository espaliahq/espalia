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

  should "stop its tenant being destroyed, rather than vanish with it" do
    tenant = create(:tenant)

    assert_raises(ActiveRecord::InvalidForeignKey) { tenant.destroy! }
    assert Tenant.exists?(tenant.id)
    assert_equal 2, TenantSettingChange.unscoped.where(tenant_id: tenant.id).count
  end

  should "keep a row unchanged once saved" do
    row = ActsAsTenant.with_tenant(tenant = create(:tenant)) { tenant.setting_changes.first }

    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(value: "Europe/Paris") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy! }
  end

  context "a size" do
    setup { @tenant = create(:tenant) }

    should "be refused unless it is a whole number, by the model and by the database" do
      ActsAsTenant.with_tenant(@tenant) do
        [ "", "five", "4.5" ].each do |value|
          assert_raises(ActiveRecord::RecordInvalid) { @tenant.setting_changes.create!(setting: "min_group_size", value:, changed_at: Time.current) }
        end
        assert_raises(ActiveRecord::StatementInvalid) do
          TenantSettingChange.insert_all!([ { id: SecureRandom.uuid_v7, tenant_id: @tenant.id, setting: "min_group_size", value: "five", changed_at: Time.current } ])
        end
      end
    end
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

  should "never end a day before the day ahead of it, when the zone moves by more than a day" do
    travel_to Time.utc(2026, 3, 1, 12)
    tenant = create(:tenant, time_zone: "Pacific/Pago_Pago")
    travel_to Time.utc(2026, 4, 11, 5)
    tenant.update!(time_zone: "Pacific/Kiritimati")

    ends = (Date.new(2026, 4, 9)..Date.new(2026, 4, 12)).map { tenant.end_of_day_then(it) }
    assert_equal ends.sort, ends
  end

  should "read a recorded size in base ten" do
    tenant = create(:tenant)
    ActsAsTenant.with_tenant(tenant) { tenant.setting_changes.create!(setting: "min_group_size", value: "08", changed_at: 1.second.from_now) }

    assert_equal 8, tenant.reload.min_group_size_at(1.minute.from_now)
  end

  should "read today's zone for a tenant with no rows at all" do
    tenant = create(:tenant, time_zone: "Europe/Paris")
    TenantSettingChange.where(tenant_id: tenant.id).delete_all

    assert_equal Time.find_zone("Europe/Paris").local(2026, 3, 15).end_of_day, tenant.reload.end_of_day_then(Date.new(2026, 3, 15))
  end

  context "the floor for a cycle's report" do
    setup do
      travel_to Time.utc(2026, 3, 1, 12)
      @tenant = create(:tenant)
      smallest_group(@tenant, 6)
      @closed_at = Time.utc(2026, 3, 10)
      travel_to Time.utc(2026, 4, 1, 12)
    end

    should "never fall below the smallest size an admin may set, though today's stored size would" do
      Tenant.where(id: @tenant.id).update_all(%(comparison_config = '{"min_group_size": "five"}'::jsonb))

      assert_equal ComparisonConfig::LOWEST_MIN_GROUP_SIZE, @tenant.reload.comparison_floor(closed_at: nil)
    end

    should "be today's size while the cycle is open" do
      smallest_group(@tenant, 4)

      assert_equal 4, @tenant.comparison_floor(closed_at: nil)
    end

    should "stay the size in force when the cycle closed, though an admin lowers it since" do
      smallest_group(@tenant, 4)

      assert_equal 6, @tenant.comparison_floor(closed_at: @closed_at)
    end

    should "never fall below the smallest size an admin may set, whatever a row holds" do
      ActsAsTenant.with_tenant(@tenant) { @tenant.setting_changes.create!(setting: "min_group_size", value: "0", changed_at: Time.utc(2026, 3, 5)) }

      assert_equal ComparisonConfig::LOWEST_MIN_GROUP_SIZE, @tenant.reload.min_group_size_at(@closed_at)
    end

    # The rule for a size raised since awaits a ruling; this asserts the larger of then and now.
    should "follow a size raised since, as the larger of then and now" do
      smallest_group(@tenant, 9)

      assert_equal 9, @tenant.comparison_floor(closed_at: @closed_at)
    end
  end
end

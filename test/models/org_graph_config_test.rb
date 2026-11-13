# frozen_string_literal: true

require "test_helper"

class OrgGraphConfigTest < ActiveSupport::TestCase
  subject { OrgGraphConfig.new }

  context "validations" do
    should validate_numericality_of(:staleness_days).only_integer.is_greater_than(0)
      .is_less_than_or_equal_to(OrgGraphConfig::MAX_STALENESS_DAYS)
    should validate_numericality_of(:retention_years).only_integer.is_greater_than(0)
      .is_less_than_or_equal_to(OrgGraphConfig::MAX_RETENTION_YEARS).allow_nil
  end

  context "the retention period" do
    should "be seven years until a tenant sets another" do
      assert_equal 7, subject.retention_years
      assert_equal Date.new(2019, 11, 13), subject.forget_left_on_or_before(Date.new(2026, 11, 13))
    end

    should "forget nobody when the tenant keeps leavers for ever" do
      assert_nil OrgGraphConfig.new(retention_years: nil).forget_left_on_or_before(Date.new(2026, 11, 13))
    end

    should "stay never once saved, where a tenant that never chose reads seven" do
      tenant = create(:tenant, org_graph_config: { staleness_days: 30 })
      assert_equal 7, tenant.org_graph_config.retention_years

      tenant.update!(org_graph_config: { staleness_days: 30, retention_years: nil })
      assert_nil tenant.reload.org_graph_config.retention_years
    end
  end

  should "default to a quarter" do
    assert_equal 90, subject.staleness_days
  end

  should "say when a fact goes stale" do
    now = Time.zone.parse("2026-11-13 09:00")

    assert_equal Time.zone.parse("2026-11-03 09:00"), OrgGraphConfig.new(staleness_days: 10).stale_before(now)
  end

  context "on a tenant" do
    should "be there with the default, and keep a saved threshold" do
      tenant = create(:tenant)
      assert_equal 90, tenant.org_graph_config.staleness_days

      tenant.update!(org_graph_config: { staleness_days: 30 })
      assert_equal 30, tenant.reload.org_graph_config.staleness_days
    end

    should "refuse a threshold that isn't a positive whole number of days" do
      tenant = build(:tenant, org_graph_config: { staleness_days: 0 })

      assert_not tenant.valid?
      assert tenant.errors.key?(:org_graph_config)
    end
  end
end

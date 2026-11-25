# frozen_string_literal: true

require "test_helper"

class OrgGraphConfigTest < ActiveSupport::TestCase
  subject { OrgGraphConfig.new }

  context "validations" do
    should validate_numericality_of(:staleness_days).only_integer.is_greater_than(0)
      .is_less_than_or_equal_to(OrgGraphConfig::MAX_STALENESS_DAYS)
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

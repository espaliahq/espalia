# frozen_string_literal: true

require "test_helper"

class TenantRetentionSettingTest < ActiveSupport::TestCase
  setup { @tenant = create(:tenant) }

  def json(**settings) = Tenant.find(@tenant.id).tap { it.org_graph_config.assign_attributes(settings) }.tap(&:save!)

  def stream(**settings)
    ActsAsTenant.with_tenant(@tenant) do
      TenantSettings::Repository.new.with_settings do |aggregate|
        aggregate.set_retention_period(settings.fetch(:retention_years, 7))
        aggregate.enable if settings[:scheduled_forgetting]
      end
    end
  end

  def scheduled
    [ TenantRetentionSetting.scheduled?(@tenant.reload), TenantRetentionSetting.scheduled_tenants.include?(@tenant) ]
  end

  context "a tenant is scheduled only when both places say so" do
    should "say no for either alone, and yes for both" do
      json(scheduled_forgetting: true)
      assert_equal [ false, false ], scheduled

      json(scheduled_forgetting: false)
      stream(scheduled_forgetting: true)
      assert_equal [ false, false ], scheduled

      json(scheduled_forgetting: true)
      assert_equal [ true, true ], scheduled
    end
  end

  context "the period that decides who is due" do
    should "be the longer of the two, and never when either is never" do
      json(retention_years: 3)
      assert_equal 7, TenantRetentionSetting.longer_period(@tenant.reload)

      stream(retention_years: 2)
      assert_equal 3, TenantRetentionSetting.longer_period(@tenant.reload)

      stream(retention_years: nil)
      assert_nil TenantRetentionSetting.longer_period(@tenant.reload)
      assert_nil TenantRetentionSetting.forget_left_on_or_before(@tenant.reload)
    end
  end
end

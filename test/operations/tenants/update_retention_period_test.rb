# frozen_string_literal: true

require "test_helper"

class Operations::Tenants::UpdateRetentionPeriodTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  def as(role, org_graph_editor: false)
    user = create(:user)
    tenant_user = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user:, role:, org_graph_editor:)
    end
    AuthorizationContext.new(user:, tenant_user:, person: nil)
  end

  def call(context: as(:admin), **params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Tenants::UpdateRetentionPeriod.call(context:, params:)
    end
  end

  def retention_years = row.retention_years
  def scheduled = row.scheduled_forgetting
  def row = TenantRetentionSetting.for(@tenant)
  def stored_config = JSON.parse(Tenant.where(id: @tenant.id).pick(Arel.sql("org_graph_config::text")))
  def handler = TenantSettings::CommandHandler.new(Tenant.find(@tenant.id))

  context "as a tenant admin" do
    should "set the period and say how it now reads" do
      result = call(retention_years: 3)

      assert_equal({ tenant_id: @tenant.id, retention_years: 3, scheduled_forgetting_stopped: false }, result)
      assert_equal 3, retention_years
    end

    should "turn scheduled forgetting off when the period makes more people due" do
      handler.enable_scheduled_forgetting { 0 }
      assert call(retention_years: 1)[:scheduled_forgetting_stopped]
      assert_not scheduled

      handler.enable_scheduled_forgetting { 0 }
      handler.set_retention_period(nil)
      assert call(retention_years: 20)[:scheduled_forgetting_stopped]
      assert_nil row.enabled_at
    end

    should "leave scheduled forgetting on when the period makes nobody new due" do
      handler.set_retention_period(3)
      handler.enable_scheduled_forgetting { 0 }

      assert_not call(retention_years: 5)[:scheduled_forgetting_stopped]
      assert_not call(never: true)[:scheduled_forgetting_stopped]
      assert scheduled
    end

    should "keep leavers for ever, then set a period again" do
      call(never: true)
      assert_nil retention_years

      call(retention_years: 7)
      assert_equal 7, retention_years
    end

    should "keep the tenant's other Org Graph settings and remove the retired keys" do
      Tenant.where(id: @tenant.id)
            .update_all(%(org_graph_config = '{"staleness_days": 30, "retention_years": 4, "scheduled_forgetting": true}'))
      call(retention_years: 2)

      assert_equal({ "staleness_days" => 30 }, stored_config)
    end

    should "refuse a period that isn't a positive whole number of years" do
      [ 0, -1, TenantSettings::Aggregate::MAX_RETENTION_YEARS + 1 ].each do |years|
        assert_raises(Operations::Base::ParameterError) { call(retention_years: years) }
      end
      assert_equal 7, retention_years
    end

    should "refuse a call that gives neither a period nor never, or both" do
      assert_raises(Operations::Base::ParameterError) { call }
      assert_raises(Operations::Base::ParameterError) { call(retention_years: 3, never: true) }
      assert_equal 7, retention_years
    end
  end

  should "refuse an Org Graph editor who isn't an admin" do
    assert_raises(Pundit::NotAuthorizedError) { call(retention_years: 1, context: as(:member, org_graph_editor: true)) }
    assert_equal 7, retention_years
  end
end

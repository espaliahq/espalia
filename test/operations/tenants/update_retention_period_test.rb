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

  def retention_years = @tenant.reload.org_graph_config.retention_years

  context "as a tenant admin" do
    should "set the period and say how it now reads" do
      result = call(retention_years: 3)

      assert_equal({ tenant_id: @tenant.id, retention_years: 3, scheduled_forgetting_stopped: false }, result)
      assert_equal 3, retention_years
    end

    should "turn scheduled forgetting off when the period makes more people due" do
      on = { scheduled_forgetting: true, scheduled_forgetting_enabled_at: Time.current }
      @tenant.update!(org_graph_config: { retention_years: 7, **on })
      assert call(retention_years: 1)[:scheduled_forgetting_stopped]
      assert_not @tenant.reload.org_graph_config.scheduled_forgetting

      @tenant.update!(org_graph_config: { retention_years: nil, **on })
      assert call(retention_years: 20)[:scheduled_forgetting_stopped]
      assert_nil @tenant.reload.org_graph_config.scheduled_forgetting_enabled_at
    end

    should "leave scheduled forgetting on when the period makes nobody new due" do
      @tenant.update!(org_graph_config: { retention_years: 3, scheduled_forgetting: true })

      assert_not call(retention_years: 5)[:scheduled_forgetting_stopped]
      assert_not call(never: true)[:scheduled_forgetting_stopped]
      assert @tenant.reload.org_graph_config.scheduled_forgetting
    end

    should "keep leavers for ever, then set a period again" do
      call(never: true)
      assert_nil retention_years

      call(retention_years: 7)
      assert_equal 7, retention_years
    end

    should "keep the tenant's other Org Graph settings" do
      @tenant.update!(org_graph_config: { staleness_days: 30 })
      call(retention_years: 2)

      assert_equal 30, @tenant.reload.org_graph_config.staleness_days
    end

    should "refuse a period that isn't a positive whole number of years" do
      [ 0, -1, OrgGraphConfig::MAX_RETENTION_YEARS + 1 ].each do |years|
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

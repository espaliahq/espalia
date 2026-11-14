# frozen_string_literal: true

require "test_helper"

class Operations::OrgGraph::UpdateStalenessThresholdTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  def as(role, org_graph_editor: false)
    tenant_user = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role:, org_graph_editor:) }
    AuthorizationContext.new(user: tenant_user.user, tenant_user:, person: nil)
  end

  def call(context: as(:admin), **params)
    ActsAsTenant.with_tenant(@tenant) { Operations::OrgGraph::UpdateStalenessThreshold.call(context:, params:) }
  end

  def staleness_days = @tenant.reload.org_graph_config.staleness_days

  should "set the threshold and say how it now reads" do
    assert_equal({ tenant_id: @tenant.id, staleness_days: 30 }, call(staleness_days: 30))
    assert_equal 30, staleness_days
  end

  should "keep the tenant's other Org Graph settings" do
    @tenant.update!(org_graph_config: { retention_years: 2 })
    call(staleness_days: 45)

    assert_equal 2, @tenant.reload.org_graph_config.retention_years
  end

  should "refuse a threshold that isn't a positive whole number of days within the limit" do
    [ 0, -5, OrgGraphConfig::MAX_STALENESS_DAYS + 1 ].each do |days|
      assert_raises(Operations::Base::ParameterError) { call(staleness_days: days) }
    end
    assert_raises(Operations::Base::ParameterError) { call }
    assert_equal OrgGraphConfig::DEFAULT_STALENESS_DAYS, staleness_days
  end

  should "let an Org Graph editor set it" do
    call(context: as(:member, org_graph_editor: true), staleness_days: 60)

    assert_equal 60, staleness_days
  end

  should "refuse a member who is not an Org Graph editor" do
    assert_raises(Pundit::NotAuthorizedError) { call(context: as(:member), staleness_days: 60) }
    assert_equal OrgGraphConfig::DEFAULT_STALENESS_DAYS, staleness_days
  end

  should "ask for approval in the app" do
    assert_equal :in_app, Operations::OrgGraph::UpdateStalenessThreshold.approval
  end
end

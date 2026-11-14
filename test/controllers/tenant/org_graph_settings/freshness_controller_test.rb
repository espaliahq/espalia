# frozen_string_literal: true

require "test_helper"

class Tenant::OrgGraphSettings::FreshnessControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @editor_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @editor_user, role: :member, org_graph_editor: true)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
  end

  should "save the threshold for an admin" do
    sign_in @admin_user
    patch tenant_org_graph_settings_freshness_path, params: { staleness_days: 30 }

    assert_redirected_to tenant_org_graph_settings_path
    assert_equal "A fact now counts as stale after 30 days.", flash[:notice]
    assert_equal 30, @tenant.reload.org_graph_config.staleness_days
  end

  should "let an Org Graph editor save it too" do
    sign_in @editor_user
    patch tenant_org_graph_settings_freshness_path, params: { staleness_days: 60 }

    assert_equal 60, @tenant.reload.org_graph_config.staleness_days
  end

  should "say why a threshold out of range wasn't saved" do
    sign_in @admin_user
    patch tenant_org_graph_settings_freshness_path, params: { staleness_days: 0 }

    assert_match(/\AThe threshold could not be saved: /, flash[:alert])
    assert_equal OrgGraphConfig::DEFAULT_STALENESS_DAYS, @tenant.reload.org_graph_config.staleness_days
  end

  should "turn a member away" do
    sign_in @member_user
    patch tenant_org_graph_settings_freshness_path, params: { staleness_days: 30 }

    assert_redirected_to root_path
    assert_equal OrgGraphConfig::DEFAULT_STALENESS_DAYS, @tenant.reload.org_graph_config.staleness_days
  end
end

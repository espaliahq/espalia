# frozen_string_literal: true

require "test_helper"

class IntegrationsPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  context "as a tenant member" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "deny index" do
      assert_not policy.index?
    end

    should "deny show" do
      assert_not policy.show?
    end

    should "deny sync" do
      assert_not policy.sync?
      assert_not policy.update_role_mappings?
      assert_not policy.update_hris_connection?
      assert_not policy.disconnect_hris?
    end

    should "deny the AI model" do
      assert_not policy.update_ai_model?
      assert_not policy.test_ai_model?
      assert_not policy.remove_ai_key?
    end

    should "deny the feedback exchange" do
      assert_not policy.update_feedback_exchange?
      assert_not policy.test_feedback_exchange?
      assert_not policy.disconnect_feedback_exchange?
    end
  end

  context "as a tenant admin" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :admin)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "allow index" do
      assert policy.index?
    end

    should "allow show" do
      assert policy.show?
    end

    should "allow sync" do
      assert policy.sync?
      assert policy.update_role_mappings?
      assert policy.update_hris_connection?
      assert policy.disconnect_hris?
    end

    should "allow the AI model" do
      assert policy.update_ai_model?
      assert policy.test_ai_model?
      assert policy.remove_ai_key?
    end

    should "allow the feedback exchange" do
      assert policy.update_feedback_exchange?
      assert policy.test_feedback_exchange?
      assert policy.disconnect_feedback_exchange?
    end
  end

  context "as a global admin" do
    setup do
      @user = create(:user, global_admin: true)
      @ctx = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "allow index" do
      assert policy.index?
    end

    should "allow show" do
      assert policy.show?
    end

    should "allow sync" do
      assert policy.sync?
      assert policy.update_role_mappings?
      assert policy.update_hris_connection?
      assert policy.disconnect_hris?
    end

    should "allow the feedback exchange" do
      assert policy.update_feedback_exchange?
      assert policy.test_feedback_exchange?
      assert policy.disconnect_feedback_exchange?
    end
  end

  context "with no tenant membership" do
    setup do
      @user = create(:user)
      @ctx = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "deny all actions" do
      assert_not policy.index?
      assert_not policy.show?
      assert_not policy.sync?
      assert_not policy.update_role_mappings?
      assert_not policy.update_hris_connection?
      assert_not policy.disconnect_hris?
      assert_not policy.remove_ai_key?
      assert_not policy.disconnect_feedback_exchange?
      assert_not policy.update_ai_model?
      assert_not policy.test_ai_model?
      assert_not policy.update_feedback_exchange?
      assert_not policy.test_feedback_exchange?
    end
  end

  private

  def policy
    IntegrationsPolicy.new(@ctx, :integrations)
  end
end

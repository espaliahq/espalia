# frozen_string_literal: true

require "test_helper"

class TenantPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  context "with no tenant membership" do
    setup do
      @user = create(:user)
      @ctx = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "deny everything" do
      assert_not policy.show?
      assert_not policy.update_theme?
      assert_not policy.update_scoring_vocabulary?
      assert_not policy.update_retention_period?
      assert_not policy.manage_org_graph_editors?
      assert_not policy.forget_person?
      assert_not policy.export_feedback?
      assert_not policy.manage_pay_bands?
      assert_not policy.manage_planning_rules?
    end
  end

  context "as a tenant member" do
    setup do
      @user = create(:user)
      @tu = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tu, person: nil)
    end

    should "deny everything" do
      assert_not policy.show?
      assert_not policy.update_theme?
      assert_not policy.update_scoring_vocabulary?
      assert_not policy.update_retention_period?
      assert_not policy.manage_org_graph_editors?
      assert_not policy.forget_person?
      assert_not policy.export_feedback?
      assert_not policy.manage_pay_bands?
      assert_not policy.manage_planning_rules?
    end
  end

  context "as an Org Graph editor" do
    setup do
      @user = create(:user)
      @tu = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member, org_graph_editor: true)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tu, person: nil)
    end

    should "deny choosing who else may edit the Org Graph" do
      assert_not policy.manage_org_graph_editors?
    end

    should "deny keeping pay bands" do
      assert_not policy.manage_pay_bands?
      assert_not policy.manage_planning_rules?
    end
  end

  context "as a tenant admin" do
    setup do
      @user = create(:user)
      @tu = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :admin)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tu, person: nil)
    end

    should "permit everything" do
      assert policy.show?
      assert policy.update_theme?
      assert policy.update_scoring_vocabulary?
      assert policy.update_retention_period?
      assert policy.manage_org_graph_editors?
      assert policy.forget_person?
      assert policy.manage_pay_bands?
      assert policy.manage_planning_rules?
    end

    should "deny the feedback export without a linked person to attribute it to" do
      assert_not policy.export_feedback?
    end

    should "permit the feedback export with a linked person" do
      person = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tu, person: person)

      assert policy.export_feedback?
    end
  end

  context "as a global admin with no tenant_user" do
    setup do
      @user = create(:user, global_admin: true)
      @ctx = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "permit everything" do
      assert policy.show?
      assert policy.update_theme?
      assert policy.update_scoring_vocabulary?
      assert policy.update_retention_period?
      assert policy.manage_org_graph_editors?
      assert policy.forget_person?
      assert policy.manage_pay_bands?
      assert policy.manage_planning_rules?
    end

    should "deny the feedback export, which needs a person to attribute it to" do
      assert_not policy.export_feedback?
    end
  end

  private

  def policy
    TenantPolicy.new(@ctx, @tenant)
  end
end

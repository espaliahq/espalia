# frozen_string_literal: true

require "test_helper"

class FrameworkPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework = ActsAsTenant.with_tenant(@tenant) do
      create(:framework_state, name: "Test Framework")
    end
  end

  context "as a tenant member" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "allow index" do
      assert policy.index?
    end

    should "allow show" do
      assert policy.show?
    end

    should "allow matrix" do
      assert policy.matrix?
    end

    should "deny suggest_edit without collaborator role" do
      assert_not policy.suggest_edit?
    end

    should "deny edit without collaborator role" do
      assert_not policy.edit?
    end

    should "deny edit_matrix without collaborator role" do
      assert_not policy.edit_matrix?
    end

    should "deny submit_suggestion without collaborator role" do
      assert_not policy.submit_suggestion?
    end

    should "deny view_suggestions without collaborator role" do
      assert_not policy.view_suggestions?
    end

    should "deny settings" do
      assert_not policy.settings?
    end

    should "deny update_settings" do
      assert_not policy.update_settings?
    end

    should "deny create_illustration" do
      assert_not policy.create_illustration?
    end

    should "deny admin" do
      assert_not policy.admin?
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

    should "allow settings" do
      assert policy.settings?
    end

    should "allow update_settings" do
      assert policy.update_settings?
    end

    should "allow create_illustration" do
      assert policy.create_illustration?
    end

    should "allow admin" do
      assert policy.admin?
    end

    should "allow suggest_edit" do
      assert policy.suggest_edit?
    end

    should "allow submit_suggestion" do
      assert policy.submit_suggestion?
    end

    should "allow view_suggestions" do
      assert policy.view_suggestions?
    end

    should "allow edit" do
      assert policy.edit?
    end

    should "allow edit_matrix" do
      assert policy.edit_matrix?
    end
  end

  context "as a global admin" do
    setup do
      @user = create(:user, global_admin: true)
      @ctx = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "allow settings" do
      assert policy.settings?
    end

    should "deny index without tenant_user" do
      assert_not policy.index?
    end
  end

  context "as a framework collaborator with editor role" do
    setup do
      @user = create(:user)
      @person = ActsAsTenant.with_tenant(@tenant) do
        p = create(:person, tenant: @tenant, email: @user.email)
        @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: p, role: :member)
        create(:framework_collaborator,
               tenant: @tenant,
               framework_id: @framework.framework_id,
               person_id: p.id,
               role: "editor")
        p
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
    end

    should "allow create_illustration" do
      assert policy.create_illustration?
    end

    should "allow update_illustration" do
      assert policy.update_illustration?
    end

    should "allow suggest_edit" do
      assert policy.suggest_edit?
    end

    should "allow submit_suggestion" do
      assert policy.submit_suggestion?
    end

    should "allow view_suggestions" do
      assert policy.view_suggestions?
    end

    should "allow edit" do
      assert policy.edit?
    end

    should "deny settings (requires tenant admin)" do
      assert_not policy.settings?
    end
  end

  context "as a framework collaborator with viewer role" do
    setup do
      @user = create(:user)
      @person = ActsAsTenant.with_tenant(@tenant) do
        p = create(:person, tenant: @tenant, email: @user.email)
        @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: p, role: :member)
        create(:framework_collaborator,
               tenant: @tenant,
               framework_id: @framework.framework_id,
               person_id: p.id,
               role: "viewer")
        p
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
    end

    should "deny create_illustration" do
      assert_not policy.create_illustration?
    end

    should "deny suggest_edit" do
      assert_not policy.suggest_edit?
    end

    should "deny submit_suggestion" do
      assert_not policy.submit_suggestion?
    end

    should "deny view_suggestions" do
      assert_not policy.view_suggestions?
    end

    should "deny edit" do
      assert_not policy.edit?
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
      assert_not policy.matrix?
      assert_not policy.settings?
      assert_not policy.create_illustration?
      assert_not policy.suggest_edit?
      assert_not policy.submit_suggestion?
      assert_not policy.view_suggestions?
      assert_not policy.edit?
      assert_not policy.edit_matrix?
    end
  end

  private

  def policy
    FrameworkPolicy.new(@ctx, @framework)
  end
end

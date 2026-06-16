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

    should "deny publish without collaborator role" do
      assert_not policy.publish?
    end

    should "deny define_migration_mapping without collaborator role" do
      assert_not policy.define_migration_mapping?
    end

    should "deny archive_capability without collaborator role" do
      assert_not policy.archive_capability?
      assert_not policy.add_capability?
      assert_not policy.add_category?
      assert_not policy.archive_category?
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

    should "allow publish" do
      assert policy.publish?
    end

    should "allow define_migration_mapping" do
      assert policy.define_migration_mapping?
    end

    should "allow add_capability and add_category" do
      assert policy.add_capability?
      assert policy.add_category?
      assert policy.archive_category?
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

    should "allow publish (editor has publish rights)" do
      assert policy.publish?
    end

    should "allow define_migration_mapping (editor has publish rights)" do
      assert policy.define_migration_mapping?
    end

    should "allow archive_capability (editor has edit rights)" do
      assert policy.archive_capability?
      assert policy.add_capability?
      assert policy.add_category?
      assert policy.archive_category?
    end

    should "deny settings (requires tenant admin)" do
      assert_not policy.settings?
    end
  end

  context "as a framework collaborator with a non-publish edit role" do
    setup do
      @user = create(:user)
      @person = ActsAsTenant.with_tenant(@tenant) do
        p = create(:person, tenant: @tenant, email: @user.email)
        @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: p, role: :member)
        create(:framework_collaborator,
               tenant: @tenant,
               framework_id: @framework.framework_id,
               person_id: p.id,
               role: "role_lead")
        p
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
    end

    should "allow edit (can suggest)" do
      assert policy.edit?
    end

    should "deny publish (publish is narrower than edit)" do
      assert_not policy.publish?
    end

    should "deny define_migration_mapping" do
      assert_not policy.define_migration_mapping?
    end

    should "allow archive_capability (edit-rights bar, broader than publish)" do
      assert policy.archive_capability?
      assert policy.add_capability?
      assert policy.add_category?
      assert policy.archive_category?
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

    should "deny publish" do
      assert_not policy.publish?
    end
  end

  context "manage_collaborators?" do
    setup do
      @other_user = create(:user)
      @other_person = ActsAsTenant.with_tenant(@tenant) do
        p = create(:person, tenant: @tenant, email: @other_user.email)
        create(:tenant_user, tenant: @tenant, user: @other_user, person: p, role: :member)
        p
      end
    end

    should "permit a tenant admin without an owner role" do
      admin = create(:user)
      tu = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: admin, role: :admin)
      end
      ctx = AuthorizationContext.new(user: admin, tenant_user: tu, person: nil)
      assert FrameworkPolicy.new(ctx, @framework).manage_collaborators?
    end

    should "permit a framework owner who is only a tenant member" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_collaborator,
               tenant: @tenant,
               framework_id: @framework.framework_id,
               person_id: @other_person.id,
               role: "owner")
      end
      ctx = AuthorizationContext.new(
        user: @other_user,
        tenant_user: @other_person.tenant_user,
        person: @other_person
      )
      assert FrameworkPolicy.new(ctx, @framework).manage_collaborators?
    end

    should "deny a framework collaborator with editor role only" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_collaborator,
               tenant: @tenant,
               framework_id: @framework.framework_id,
               person_id: @other_person.id,
               role: "editor")
      end
      ctx = AuthorizationContext.new(
        user: @other_user,
        tenant_user: @other_person.tenant_user,
        person: @other_person
      )
      assert_not FrameworkPolicy.new(ctx, @framework).manage_collaborators?
    end

    should "deny a tenant member with no collaborator role" do
      ctx = AuthorizationContext.new(
        user: @other_user,
        tenant_user: @other_person.tenant_user,
        person: @other_person
      )
      assert_not FrameworkPolicy.new(ctx, @framework).manage_collaborators?
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
      assert_not policy.publish?
      assert_not policy.define_migration_mapping?
      assert_not policy.archive_capability?
      assert_not policy.add_capability?
      assert_not policy.add_category?
      assert_not policy.archive_category?
    end
  end

  private

  def policy
    FrameworkPolicy.new(@ctx, @framework)
  end
end

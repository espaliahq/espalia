# frozen_string_literal: true

require "test_helper"

class FrameworkSuggestionPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @framework = ActsAsTenant.with_tenant(@tenant) do
      create(:framework_state, name: "Test Framework")
    end
  end

  context "as a non-member" do
    setup do
      @user = create(:user)
      @ctx = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
      @suggestion = build_suggestion(target_entity_type: "role_illustration")
    end

    should "deny everything" do
      assert_not policy.index?
      assert_not policy.show?
      assert_not policy.create?
      assert_not policy.approve?
      assert_not policy.reject?
      assert_not policy.amend?
      assert_not policy.withdraw?
    end
  end

  context "as a tenant member without collaborator role" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
      @suggestion = build_suggestion(target_entity_type: "role_illustration")
    end

    should "allow viewing" do
      assert policy.index?
      assert policy.show?
    end

    should "allow submitting suggestions" do
      assert policy.create?
    end

    should "deny approving" do
      assert_not policy.approve?
      assert_not policy.reject?
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

    should "approve tier 1 illustrations" do
      @suggestion = build_suggestion(target_entity_type: "role_illustration")
      assert policy.approve?
      assert policy.reject?
    end

    should "approve tier 2 capability descriptions" do
      @suggestion = build_suggestion(target_entity_type: "capability")
      assert policy.approve?
    end

    should "approve tier 3 expectations" do
      @suggestion = build_suggestion(target_entity_type: "behavioural_expectation")
      assert policy.approve?
    end
  end

  context "as a framework collaborator with capability_lead role" do
    setup do
      @user = create(:user)
      @person = ActsAsTenant.with_tenant(@tenant) do
        p = create(:person, tenant: @tenant, email: @user.email)
        @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: p, role: :member)
        create(:framework_collaborator,
               tenant: @tenant,
               framework_id: @framework.framework_id,
               person_id: p.id,
               role: "capability_lead")
        p
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
    end

    should "approve tier 1 illustrations" do
      @suggestion = build_suggestion(target_entity_type: "role_illustration")
      assert policy.approve?
    end

    should "approve tier 2 capability descriptions" do
      @suggestion = build_suggestion(target_entity_type: "capability")
      assert policy.approve?
    end

    should "approve tier 3 behavioural expectations" do
      @suggestion = build_suggestion(target_entity_type: "behavioural_expectation")
      assert policy.approve?
    end
  end

  context "as a framework collaborator with role_lead role" do
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

    should "approve tier 1 illustrations" do
      @suggestion = build_suggestion(target_entity_type: "role_illustration")
      assert policy.approve?
    end

    should "deny tier 2 capability descriptions" do
      @suggestion = build_suggestion(target_entity_type: "capability")
      assert_not policy.approve?
    end

    should "deny tier 3 behavioural expectations" do
      @suggestion = build_suggestion(target_entity_type: "behavioural_expectation")
      assert_not policy.approve?
    end
  end

  context "as the author of a pending suggestion" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
      @suggestion = build_suggestion(
        target_entity_type: "role_illustration", author_id: @user.id.to_s, status: "pending"
      )
    end

    should "allow amending own pending suggestion" do
      assert policy.amend?
    end

    should "allow withdrawing own pending suggestion" do
      assert policy.withdraw?
    end
  end

  context "as the author of an approved suggestion" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
      @suggestion = build_suggestion(
        target_entity_type: "role_illustration", author_id: @user.id.to_s, status: "approved"
      )
    end

    should "deny amending non-pending suggestion" do
      assert_not policy.amend?
    end

    should "deny withdrawing non-pending suggestion" do
      assert_not policy.withdraw?
    end
  end

  context "as a non-author tenant member" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, role: :member)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
      @suggestion = build_suggestion(
        target_entity_type: "role_illustration", author_id: SecureRandom.uuid_v7, status: "pending"
      )
    end

    should "deny amending someone else's suggestion" do
      assert_not policy.amend?
    end

    should "deny withdrawing someone else's suggestion" do
      assert_not policy.withdraw?
    end
  end

  private

  def policy
    FrameworkSuggestionPolicy.new(@ctx, @suggestion)
  end

  def build_suggestion(target_entity_type:, author_id: SecureRandom.uuid_v7, status: "pending")
    ActsAsTenant.with_tenant(@tenant) do
      build(:framework_suggested_edit,
            tenant: @tenant,
            framework_id: @framework.framework_id,
            target_entity_type: target_entity_type,
            author_id: author_id,
            status: status)
    end
  end
end

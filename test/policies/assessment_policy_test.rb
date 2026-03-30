# frozen_string_literal: true

require "test_helper"

class AssessmentPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, name: "Developer")
      @manager = create(:person, tenant: @tenant, name: "Manager")
      @person.update!(manager: @manager)

      @framework = create(:framework_state, name: "Test Framework")
      @assignment = create(:person_framework_assignment,
                           tenant: @tenant,
                           person_id: @person.id,
                           framework_id: @framework.framework_id)
    end
  end

  context "as the assigned person" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, person: @person)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
    end

    should "allow show" do
      assert policy.show?
    end

    should "allow matrix" do
      assert policy.matrix?
    end

    should "allow create_self_rating" do
      assert policy.create_self_rating?
    end

    should "deny create_manager_rating" do
      assert_not policy.create_manager_rating?
    end
  end

  context "as the person's manager" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user, person: @manager)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @manager)
    end

    should "allow show" do
      assert policy.show?
    end

    should "allow create_manager_rating" do
      assert policy.create_manager_rating?
    end

    should "deny create_self_rating" do
      assert_not policy.create_self_rating?
    end
  end

  context "as an unrelated person" do
    setup do
      @user = create(:user)
      @other_person = ActsAsTenant.with_tenant(@tenant) do
        p = create(:person, tenant: @tenant, name: "Other")
        @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: p)
        p
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @other_person)
    end

    should "deny show" do
      assert_not policy.show?
    end

    should "deny create_self_rating" do
      assert_not policy.create_self_rating?
    end

    should "deny create_manager_rating" do
      assert_not policy.create_manager_rating?
    end
  end

  context "with no person linked" do
    setup do
      @user = create(:user)
      @tenant_user = ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @user)
      end
      @ctx = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "deny all actions" do
      assert_not policy.index?
      assert_not policy.show?
      assert_not policy.create_self_rating?
      assert_not policy.create_manager_rating?
    end
  end

  private

  def policy
    AssessmentPolicy.new(@ctx, @assignment)
  end
end

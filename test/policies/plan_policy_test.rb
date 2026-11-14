# frozen_string_literal: true

require "test_helper"

class PlanPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.current_tenant = @tenant
    @creator = create(:person, tenant: @tenant)
    @plan = Struct.new(:created_by_id).new(@creator.id)
  end

  teardown { ActsAsTenant.current_tenant = nil }

  context "the plan's creator" do
    setup { @context = context_for(@creator) }

    should "open, rename and delete it" do
      policy = PlanPolicy.new(@context, @plan)
      assert policy.show?
      assert policy.update?
      assert policy.destroy?
    end

    should "not create a plan while only a member" do
      assert_not PlanPolicy.new(@context, nil).create?
    end
  end

  context "a tenant admin who did not create the plan" do
    setup { @context = context_for(create(:person, tenant: @tenant), role: :admin) }

    should "create a plan of their own" do
      assert PlanPolicy.new(@context, nil).create?
    end

    should "not open someone else's" do
      policy = PlanPolicy.new(@context, @plan)
      assert_not policy.show?
      assert_not policy.update?
      assert_not policy.destroy?
    end
  end

  context "an admin with no person" do
    setup do
      user = create(:user)
      @context = AuthorizationContext.new(user:, tenant_user: create(:tenant_user, tenant: @tenant, user:, role: :admin), person: nil)
    end

    should "open no plan, even one with no creator" do
      assert_not PlanPolicy.new(@context, Struct.new(:created_by_id).new(nil)).show?
    end
  end

  context "someone outside the tenant" do
    setup { @context = AuthorizationContext.new(user: create(:user), tenant_user: nil, person: @creator) }

    should "do nothing" do
      policy = PlanPolicy.new(@context, @plan)
      assert_not policy.create?
      assert_not policy.show?
      assert_not policy.update?
    end
  end

  private

  def context_for(person, role: :member)
    user = create(:user)
    AuthorizationContext.new(user:, tenant_user: create(:tenant_user, tenant: @tenant, user:, person:, role:), person:)
  end
end

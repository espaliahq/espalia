# frozen_string_literal: true

require "test_helper"

class AssessmentCyclePolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @cycle = create(:assessment_cycle, tenant: @tenant)
    end
  end

  context "as a non-member (no tenant_user)" do
    setup do
      @user = create(:user)
      @context = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "deny every action" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      refute policy.index?
      refute policy.show?
      refute policy.define?
      refute policy.enroll?
      refute policy.unenroll?
      refute policy.close?
    end
  end

  context "as a tenant member" do
    setup do
      @user = create(:user)
      @tenant_user = create(:tenant_user, user: @user, tenant: @tenant, role: :member)
      @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "permit show" do
      assert AssessmentCyclePolicy.new(@context, @cycle).show?
    end

    should "deny index and mutation actions" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      refute policy.index?
      refute policy.define?
      refute policy.enroll?
      refute policy.unenroll?
      refute policy.close?
    end
  end

  context "as a tenant admin" do
    setup do
      @user = create(:user)
      @tenant_user = create(:tenant_user, user: @user, tenant: @tenant, role: :admin)
      @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: nil)
    end

    should "permit every action" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      assert policy.index?
      assert policy.show?
      assert policy.define?
      assert policy.enroll?
      assert policy.unenroll?
      assert policy.close?
    end
  end

  context "as a global admin" do
    setup do
      @user = create(:user, global_admin: true)
      @context = AuthorizationContext.new(user: @user, tenant_user: nil, person: nil)
    end

    should "permit every action" do
      policy = AssessmentCyclePolicy.new(@context, @cycle)
      assert policy.index?
      assert policy.show?
      assert policy.define?
      assert policy.enroll?
      assert policy.unenroll?
      assert policy.close?
    end
  end
end

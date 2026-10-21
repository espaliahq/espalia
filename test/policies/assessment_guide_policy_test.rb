# frozen_string_literal: true

require "test_helper"

class AssessmentGuidePolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
  end

  context "#show?" do
    should "permit a tenant member" do
      tenant_user = ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, role: :member) }
      context = AuthorizationContext.new(user: tenant_user.user, tenant_user: tenant_user, person: nil)

      assert AssessmentGuidePolicy.new(context, :assessment_guide).show?
    end

    should "permit a global admin outside the tenant" do
      context = AuthorizationContext.new(user: build(:user, global_admin: true), tenant_user: nil, person: nil)

      assert AssessmentGuidePolicy.new(context, :assessment_guide).show?
    end

    should "deny a user with no membership" do
      context = AuthorizationContext.new(user: build(:user), tenant_user: nil, person: nil)

      assert_not AssessmentGuidePolicy.new(context, :assessment_guide).show?
    end

    should "deny when there is no user" do
      context = AuthorizationContext.new(user: nil, tenant_user: nil, person: nil)

      assert_not AssessmentGuidePolicy.new(context, :assessment_guide).show?
    end
  end
end

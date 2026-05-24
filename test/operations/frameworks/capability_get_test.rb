# frozen_string_literal: true

require "test_helper"

# Confirms the capability drill-in shape: description, status, bindings
# (with role + weight), expectations per level, illustrations per
# expectation grouped by role.
class Operations::Frameworks::CapabilityGetTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email)
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      create(:framework_level, role_id: @role.role_id, ordinal: 3, title: "Senior", code: "E3")

      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id,
                    name: "Critical Thinking", description: "Breaks down problems systematically.")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.5)
      exp2 = create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Asks clarifying questions")
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 3, description: "Identifies root causes")

      # One illustration on the L2 expectation
      FrameworkState::RoleIllustration.create!(
        tenant: @tenant, expectation_id: exp2.expectation_id,
        illustration_id: SecureRandom.uuid_v7, role_id: @role.role_id,
        description: "Pairs with senior on diagnosis", ordinal: 1, stable_id: SecureRandom.uuid_v7
      )
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Frameworks::CapabilityGet.call(
        context: @context,
        params: { framework_id: @framework_id, capability_id: @cap.capability_id }
      )
    end
  end

  context "structure" do
    should "return capability identity, description, status, category" do
      result = call_op
      assert_equal "Critical Thinking", result[:name]
      assert_equal "Breaks down problems systematically.", result[:description]
      assert_equal "active", result[:status]
      assert_equal "Thinking", result.dig(:category, :name)
    end

    should "include bindings with role + weight" do
      result = call_op
      binding = result[:bindings].first
      assert_equal "E", binding.dig(:role, :code)
      assert_equal 1.5, binding[:weight]
    end

    should "list expectations per level, ordered by level_ordinal" do
      result = call_op
      assert_equal [ 2, 3 ], result[:expectations].map { |e| e[:level_ordinal] }
      assert_equal "Asks clarifying questions", result[:expectations].first[:description]
    end

    should "embed illustrations under the matching expectation, grouped by role" do
      result = call_op
      l2 = result[:expectations].find { |e| e[:level_ordinal] == 2 }
      assert_equal 1, l2[:illustrations].size
      assert_equal "E", l2[:illustrations].first.dig(:role, :code)
      assert_equal "Pairs with senior on diagnosis", l2[:illustrations].first[:description]
    end
  end
end

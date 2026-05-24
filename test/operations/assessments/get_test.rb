# frozen_string_literal: true

require "test_helper"

# Confirms the assessment payload is a strict superset of the framework
# payload — same `framework:` subtree plus the assignment + cycle
# overlay. The shape-parity assertion is the load-bearing test: LLMs
# that learn one shape immediately understand the other.
class Operations::Assessments::GetTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")

      PersonDevelopment::CommandHandler.new
        .assign_to_framework(@person.id, @framework_id, @role.role_id, @level.level_id)

      cycles_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycles_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycles_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_assessment_op
    ActsAsTenant.with_tenant(@tenant) { Operations::Assessments::Get.call(context: @context, params: { assignment_id: @assignment.id }) }
  end

  def call_framework_op
    ActsAsTenant.with_tenant(@tenant) { Operations::Frameworks::Get.call(context: @context, params: { framework_id: @framework_id }) }
  end

  context "structure" do
    should "embed the framework payload under :framework" do
      assert_equal "Eng", call_assessment_op.dig(:framework, :name)
    end

    should "expose assignment + current_cycle overlay alongside :framework" do
      result = call_assessment_op
      assert_equal @assignment.id, result.dig(:assignment, :id)
      assert_equal "E", result.dig(:assignment, :role, :code)
      assert_equal 2, result.dig(:assignment, :level, :ordinal)
      assert_equal "Q1", result.dig(:current_cycle, :name)
      assert_equal "open", result.dig(:current_cycle, :status)
    end
  end

  context "shape parity with Frameworks::Get" do
    # If this test fails, the LLM's mental model of the framework shape
    # is no longer transferable to assessments. Fix by matching keys, or
    # explicitly document the divergence and update this test.
    should "the :framework subtree matches Frameworks::Get's payload exactly" do
      assessment_framework = call_assessment_op[:framework]
      framework_only       = call_framework_op

      assert_equal framework_only.keys.sort, assessment_framework.keys.sort
      framework_only.each do |k, v|
        if v.is_a?(Array) && v.first.is_a?(Hash)
          assert_equal v.first.keys.sort, assessment_framework[k].first.keys.sort,
            "key set drift in :#{k} children"
        end
      end
    end
  end

  context "policy" do
    should "deny callers who don't own or manage the assessment" do
      other_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        other_person = create(:person, tenant: @tenant, email: other_user.email)
        tu = create(:tenant_user, tenant: @tenant, user: other_user, person: other_person, role: :member)
        ctx = AuthorizationContext.new(user: other_user, tenant_user: tu, person: other_person)
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Assessments::Get.call(context: ctx, params: { assignment_id: @assignment.id })
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

# Confirms the assessment capability payload is a strict superset of the
# framework capability payload — same top-level keys, same expectation
# structure — plus a `ratings:` key per expectation and a top-level
# `cycle_id`.
class Operations::Assessments::CapabilityGetTest < ActiveSupport::TestCase
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
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Asks clarifying questions")

      pd_handler     = PersonDevelopment::CommandHandler.new
      cycles_handler = AssessmentCycles::CommandHandler.new
      pd_handler.assign_to_framework(@person.id, @framework_id, @role.role_id, @level.level_id)
      @cycle_id = SecureRandom.uuid_v7
      cycles_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycles_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)
      # Self-rate the L2 expectation as "consistent"
      pd_handler.rate_self(@person.id, @framework_id, @cap.stable_id,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_assessment_op
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::CapabilityGet.call(
        context: @context,
        params: { assignment_id: @assignment.id, capability_id: @cap.capability_id }
      )
    end
  end

  def call_framework_op
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Frameworks::CapabilityGet.call(
        context: @context,
        params: { framework_id: @framework_id, capability_id: @cap.capability_id }
      )
    end
  end

  context "ratings overlay" do
    should "expose self-rating on the matching expectation" do
      result = call_assessment_op
      l2 = result[:expectations].find { |e| e[:level_ordinal] == 2 }
      assert_equal "consistent", l2.dig(:ratings, :self)
      assert_nil l2.dig(:ratings, :manager)
      assert_nil l2.dig(:ratings, :aligned)
    end

    should "expose the cycle_id at the top level" do
      assert_equal @cycle_id, call_assessment_op[:cycle_id]
    end

    should "return nil ratings on expectations the assessee hasn't rated" do
      # No rating exists for any other level, but the expectation row
      # should still carry a ratings key (all values nil) so the LLM
      # gets a consistent shape.
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_behavioural_expectation,
          capability_id: @cap.capability_id, level_ordinal: 3, description: "Identifies root causes")
      end
      result = call_assessment_op
      l3 = result[:expectations].find { |e| e[:level_ordinal] == 3 }
      assert_equal({ self: nil, manager: nil, aligned: nil }, l3[:ratings])
    end
  end

  context "shape parity with Frameworks::CapabilityGet" do
    should "the framework-shaped keys are unchanged; only :ratings and :cycle_id are added" do
      framework_payload = call_framework_op
      assessment_payload = call_assessment_op

      # Top-level: assessment adds :cycle_id and (per-expectation) :ratings.
      added_keys = assessment_payload.keys - framework_payload.keys
      assert_equal [ :cycle_id ], added_keys

      framework_payload.each do |k, v|
        next unless v.is_a?(Array) && v.first.is_a?(Hash)
        # Each child row's framework keys must be present in the assessment row.
        f_keys = v.first.keys
        a_keys = assessment_payload[k].first.keys
        assert (f_keys - a_keys).empty?,
          "drift in :#{k} children — framework keys #{f_keys - a_keys} missing from assessment payload"
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
          Operations::Assessments::CapabilityGet.call(
            context: ctx,
            params: { assignment_id: @assignment.id, capability_id: @cap.capability_id }
          )
        end
      end
    end
  end
end

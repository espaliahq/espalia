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

  context "the capability order" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        cat = FrameworkState::CapabilityCategory.find_by!(name: "Thinking")
        FrameworkState::Capability.find_by!(name: "Critical Thinking").update!(ordinal: 3)
        create(:framework_capability, category_id: cat.category_id, name: "Strategic Thinking", ordinal: 1)
        create(:framework_capability, category_id: cat.category_id, name: "Data Informed", ordinal: 2)
        cat.capabilities.reload.each do |cap|
          create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: @role.role_id)
          create(:framework_behavioural_expectation, capability_id: cap.capability_id, level_ordinal: 2)
        end
      end
    end

    should "match the order the assessment page renders" do
      page_order = ActsAsTenant.with_tenant(@tenant) do
        Assessments::MatrixDataBuilder
          .for_lens(lens: Assessments::Lens.home(@assignment), context: :self)
          .dig(:categories, 0, :capabilities).map { |c| c[:capability].name }
      end

      assert_equal [ "Strategic Thinking", "Data Informed", "Critical Thinking" ], page_order
      assert_equal page_order,
        call_assessment_op.dig(:framework, :categories, 0, :capabilities).map { |c| c[:name] }
    end
  end

  context "the scoring roll-up" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        cap = FrameworkState::Capability.find_by!(name: "Critical Thinking")
        create(:framework_capability_role_binding,
          capability_id: cap.capability_id, role_id: @role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation,
          capability_id: cap.capability_id, level_ordinal: 2, description: "Asks clarifying questions")
        PersonDevelopment::CommandHandler.new.rate_self(
          @person.id, @framework_id, cap.stable_id,
          level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id
        )
      end
    end

    should "carry the score with its parts and the scale spelled out" do
      scoring = call_assessment_op[:scoring]

      assert_equal 100, scoring[:score]
      assert_equal "top_of_ladder", scoring[:state]
      assert_equal 100, scoring.dig(:components, :assessed_level)
      assert_equal 0, scoring.dig(:components, :missing_below_assessed_level)
      assert_equal "percent_of_assessed_level_expectations", scoring.dig(:scale, :unit)
      assert_equal "E2", scoring.dig(:scale, :assessed_level)
    end

    should "carry the framework's own thresholds rather than assumed ones" do
      thresholds = call_assessment_op.dig(:scoring, :thresholds)

      assert_equal 80, thresholds[:underperforming]
      assert_equal 95, thresholds[:meeting]
      assert_equal 150, thresholds[:mastering]
    end

    should "roll up per category with the coverage counts the screen shows" do
      categories = call_assessment_op.dig(:scoring, :categories)

      thinking = categories.find { |c| c[:name] == "Thinking" }
      assert_equal 100, thinking[:score]
      assert_equal "top_of_ladder", thinking[:state]
      assert_equal 1, thinking[:rated_at_assessed_level]
      assert_equal 1, thinking[:total_at_assessed_level]
    end

    should "name nothing as blocked when nothing is" do
      assert_empty call_assessment_op.dig(:scoring, :blocked)
      assert_empty call_assessment_op.dig(:scoring, :unrated)
      assert_equal false, call_assessment_op.dig(:scoring, :promotion_ready)
    end

    # #485: only a rating can block; a capability nobody has rated is
    # reported apart, as the reason the state is held.
    should "report an unrated capability apart from the blocked ones" do
      ActsAsTenant.with_tenant(@tenant) do
        cat = FrameworkState::CapabilityCategory.find_by!(name: "Thinking")
        cap = create(:framework_capability, category_id: cat.category_id, name: "Code Review")
        create(:framework_capability_role_binding,
          capability_id: cap.capability_id, role_id: @role.role_id, weight: 1.0)
        create(:framework_behavioural_expectation,
          capability_id: cap.capability_id, level_ordinal: 2, description: "Reviews thoroughly")
        @code_review = cap.stable_id
      end
      scoring = call_assessment_op[:scoring]

      assert_empty scoring[:blocked]
      assert_equal [ { capability_stable_id: @code_review, name: "Code Review" } ], scoring[:unrated]
    end
  end

  context "unplaced feedback" do
    should "count the items waiting to be placed, for a viewer who sees the evidence" do
      assert_equal 0, call_assessment_op.dig(:unplaced_feedback, :count)
      ActsAsTenant.with_tenant(@tenant) do
        peer = create(:person, tenant: @tenant, name: "Peer")
        PersonDevelopment::CommandHandler.new.record_evidence(@person.id, @framework_id, SecureRandom.uuid_v7,
          source: "peer", evidence_type: "peer_feedback", content: "Great call", author_id: peer.id)
      end
      assert_equal 1, call_assessment_op.dig(:unplaced_feedback, :count)
    end

    should "withhold the count from a tenant admin outside the chain, as the web does" do
      admin_user = create(:user)
      admin_ctx = ActsAsTenant.with_tenant(@tenant) do
        admin = create(:person, tenant: @tenant, email: admin_user.email, name: "Admin")
        tu = create(:tenant_user, tenant: @tenant, user: admin_user, person: admin, role: :admin)
        peer = create(:person, tenant: @tenant, name: "Peer")
        PersonDevelopment::CommandHandler.new.record_evidence(@person.id, @framework_id, SecureRandom.uuid_v7,
          source: "peer", evidence_type: "peer_feedback", content: "Great call", author_id: peer.id)
        AuthorizationContext.new(user: admin_user, tenant_user: tu, person: admin)
      end
      result = ActsAsTenant.with_tenant(@tenant) do
        Operations::Assessments::Get.call(context: admin_ctx, params: { assignment_id: @assignment.id })
      end
      assert_nil result[:unplaced_feedback]
    end
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

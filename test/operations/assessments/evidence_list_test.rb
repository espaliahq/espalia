# frozen_string_literal: true

require "test_helper"

# Covers the assessment → capability → evidence read drill-in: scoping by
# capability and level, multi-link exposure, active-only filtering,
# identifier resolution (capability_id or stable_id), and the policy gate.
class Operations::Assessments::EvidenceListTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role  = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      create(:framework_level, role_id: @role.role_id, ordinal: 3, title: "Senior", code: "E3")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      @other_cap = create(:framework_capability, category_id: cat.category_id, name: "Communication")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_capability_role_binding,
        capability_id: @other_cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Asks clarifying questions")

      @pd = PersonDevelopment::CommandHandler.new
      @pd.assign_to_framework(@person.id, @framework_id, @role.role_id,
        FrameworkState::Level.find_by(role_id: @role.role_id, ordinal: 2).level_id)
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first

      # One item on (cap, L2), also linked to (other_cap, L3).
      @evidence_id = SecureRandom.uuid_v7
      @pd.record_evidence(@person.id, @framework_id, @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome",
        title: "Shipped X", content: "Led the migration", author_id: @person.id, valence: "demonstrated")
      @pd.add_evidence_link(@person.id, @framework_id, @evidence_id,
        capability_stable_id: @other_cap.stable_id, level_ordinal: 3, linked_by_id: @person.id, valence: "demonstrated")
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op(params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::EvidenceList.call(context: @context, params: params)
    end
  end

  context "scoping" do
    should "list evidence linked to the capability across levels when no level given" do
      result = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id)
      assert_equal 1, result[:evidence].size
      assert_equal @evidence_id, result[:evidence].first[:evidence_id]
      assert_nil result[:level_ordinal]
    end

    should "narrow to a single cell when level_ordinal is given" do
      hit = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id, level_ordinal: 2)
      assert_equal 1, hit[:evidence].size

      miss = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id, level_ordinal: 3)
      assert_empty miss[:evidence]
    end

    should "surface a multi-linked item under its other capability too" do
      result = call_op(assignment_id: @assignment.id, capability_stable_id: @other_cap.stable_id)
      assert_equal [ @evidence_id ], result[:evidence].map { |e| e[:evidence_id] }
    end
  end

  context "item payload" do
    should "carry content, author, and the full set of active links" do
      item = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id)[:evidence].first
      assert_equal "project_outcome", item[:evidence_type]
      assert_equal "Shipped X", item[:title]
      assert_equal "Led the migration", item[:content]
      assert_equal "self", item[:source]
      assert_equal @person.id, item.dig(:author, :id)
      assert_equal "Alice", item.dig(:author, :name)
      assert_includes item[:links], { capability_stable_id: @cap.stable_id, level_ordinal: 2, valence: "demonstrated" }
      assert_includes item[:links], { capability_stable_id: @other_cap.stable_id, level_ordinal: 3, valence: "demonstrated" }
    end
  end

  context "active-only" do
    should "omit withdrawn items" do
      ActsAsTenant.with_tenant(@tenant) do
        @pd.withdraw_evidence(@person.id, @framework_id, @evidence_id, withdrawn_by_id: @person.id)
      end
      result = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id)
      assert_empty result[:evidence]
    end

    should "omit a removed link but keep the item under its remaining cell" do
      ActsAsTenant.with_tenant(@tenant) do
        @pd.remove_evidence_link(@person.id, @framework_id, @evidence_id,
          capability_stable_id: @other_cap.stable_id, level_ordinal: 3, removed_by_id: @person.id)
      end
      gone = call_op(assignment_id: @assignment.id, capability_stable_id: @other_cap.stable_id)
      assert_empty gone[:evidence]

      kept = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id)
      item = kept[:evidence].first
      assert_equal [ { capability_stable_id: @cap.stable_id, level_ordinal: 2, valence: "demonstrated" } ], item[:links]
    end
  end

  context "identifier resolution" do
    should "accept a version-specific capability_id in the capability_stable_id argument" do
      result = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.capability_id)
      assert_equal [ @evidence_id ], result[:evidence].map { |e| e[:evidence_id] }
      assert_equal @cap.stable_id, result[:capability_stable_id]
    end

    should "raise when the identifier matches no capability in the framework" do
      assert_raises(ActiveRecord::RecordNotFound) do
        call_op(assignment_id: @assignment.id, capability_stable_id: SecureRandom.uuid_v7)
      end
    end
  end

  context "policy" do
    should "deny a peer who neither owns nor manages the assessment" do
      other_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        other_person = create(:person, tenant: @tenant, email: other_user.email)
        tu = create(:tenant_user, tenant: @tenant, user: other_user, person: other_person, role: :member)
        ctx = AuthorizationContext.new(user: other_user, tenant_user: tu, person: other_person)
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Assessments::EvidenceList.call(
            context: ctx,
            params: { assignment_id: @assignment.id, capability_stable_id: @cap.stable_id }
          )
        end
      end
    end

    should "permit the assessee's manager to see all evidence" do
      mgr_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        manager = create(:person, tenant: @tenant, email: mgr_user.email, name: "Boss")
        tu = create(:tenant_user, tenant: @tenant, user: mgr_user, person: manager, role: :member)
        @person.update!(manager: manager)
        ctx = AuthorizationContext.new(user: mgr_user, tenant_user: tu, person: manager)
        result = Operations::Assessments::EvidenceList.call(
          context: ctx,
          params: { assignment_id: @assignment.id, capability_stable_id: @cap.stable_id }
        )
        assert_equal [ @evidence_id ], result[:evidence].map { |e| e[:evidence_id] }
      end
    end
  end
end

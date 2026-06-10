# frozen_string_literal: true

require "test_helper"

# Covers the assessment → capability → comments read drill-in: thread
# nesting, level scoping, active-only filtering, identifier resolution, and
# the policy gate (peers, who can't see the assessment, are denied).
class Operations::Assessments::CommentsListTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      @tenant_user = create(:tenant_user, tenant: @tenant, user: @user, person: @person, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      @role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      create(:framework_level, role_id: @role.role_id, ordinal: 3, title: "Senior", code: "E3")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Asks clarifying questions")

      @pd = PersonDevelopment::CommandHandler.new
      @pd.assign_to_framework(@person.id, @framework_id, @role.role_id,
        FrameworkState::Level.find_by(role_id: @role.role_id, ordinal: 2).level_id)
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first

      # Top-level comment on (cap, L2) with one reply, plus a separate
      # top-level comment on (cap, L3).
      @parent_id = post_comment("Good progress here", level: 2)
      @reply_id = post_comment("Agreed — strong examples", level: 2, parent_id: @parent_id)
      @l3_id = post_comment("Stretch goal for L3", level: 3)
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def post_comment(body, level:, parent_id: nil)
    id = SecureRandom.uuid_v7
    @pd.post_comment(@person.id, @framework_id, id,
      commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
      capability_stable_id: @cap.stable_id, level_ordinal: level,
      body: body, author_id: @person.id, parent_id: parent_id)
    id
  end

  def call_op(params)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::CommentsList.call(context: @context, params: params)
    end
  end

  context "threading" do
    should "nest replies under their top-level comment" do
      result = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id, level_ordinal: 2)
      assert_equal 1, result[:comments].size
      parent = result[:comments].first
      assert_equal @parent_id, parent[:id]
      assert_equal "Good progress here", parent[:body]
      assert_equal [ @reply_id ], parent[:replies].map { |r| r[:id] }
      assert_equal "Agreed — strong examples", parent[:replies].first[:body]
    end
  end

  context "scoping" do
    should "return all levels' threads when no level given" do
      result = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id)
      assert_equal [ @l3_id, @parent_id ].sort, result[:comments].map { |c| c[:id] }.sort
    end

    should "narrow to one level when level_ordinal is given" do
      result = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id, level_ordinal: 3)
      assert_equal [ @l3_id ], result[:comments].map { |c| c[:id] }
      assert_empty result[:comments].first[:replies]
    end
  end

  context "active-only" do
    should "omit soft-deleted comments" do
      ActsAsTenant.with_tenant(@tenant) do
        @pd.delete_comment(@person.id, @framework_id, @l3_id, deleted_by_id: @person.id)
      end
      result = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id)
      assert_equal [ @parent_id ], result[:comments].map { |c| c[:id] }
    end
  end

  context "payload" do
    should "carry author, body, level, and timestamps" do
      parent = call_op(assignment_id: @assignment.id, capability_stable_id: @cap.stable_id,
        level_ordinal: 2)[:comments].first
      assert_equal @person.id, parent.dig(:author, :id)
      assert_equal "Alice", parent.dig(:author, :name)
      assert_equal 2, parent[:level_ordinal]
      assert_equal @cap.stable_id, parent[:capability_stable_id]
      assert parent[:posted_at].present?
      assert_nil parent[:edited_at]
    end
  end

  context "policy" do
    should "deny a peer who cannot see the assessment" do
      other_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        other_person = create(:person, tenant: @tenant, email: other_user.email)
        tu = create(:tenant_user, tenant: @tenant, user: other_user, person: other_person, role: :member)
        ctx = AuthorizationContext.new(user: other_user, tenant_user: tu, person: other_person)
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Assessments::CommentsList.call(
            context: ctx,
            params: { assignment_id: @assignment.id, capability_stable_id: @cap.stable_id }
          )
        end
      end
    end
  end
end

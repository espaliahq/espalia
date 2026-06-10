# frozen_string_literal: true

require "test_helper"

# Covers editing a comment over MCP: body replacement, author-only
# authorisation, and the blank-body guard.
class Operations::Assessments::EditCommentTest < ActiveSupport::TestCase
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
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "X")
      @pd = PersonDevelopment::CommandHandler.new
      @pd.assign_to_framework(@person.id, @framework_id, @role.role_id,
        FrameworkState::Level.find_by(role_id: @role.role_id, ordinal: 2).level_id)
      @assignment = PersonFrameworkAssignment.for_person(@person.id).first

      @comment_id = SecureRandom.uuid_v7
      @pd.post_comment(@person.id, @framework_id, @comment_id,
        commentable_type: PersonDevelopmentComment::ASSESSMENT_CELL,
        capability_stable_id: @cap.stable_id, level_ordinal: 2,
        body: "Original", author_id: @person.id)
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op(context: @context, **overrides)
    params = { assignment_id: @assignment.id, comment_id: @comment_id, body: "Edited" }.merge(overrides)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::EditComment.call(context: context, params: params)
    end
  end

  should "replace the body and stamp edited_at" do
    result = call_op
    assert_equal "Edited", result[:body]
    assert result[:edited_at].present?

    reloaded = ActsAsTenant.with_tenant(@tenant) { PersonDevelopmentComment.find(@comment_id) }
    assert_equal "Edited", reloaded.body
    assert_equal @person.id, reloaded.edited_by_id
  end

  should "reject a blank body" do
    assert_raises(Operations::Base::ParameterError) { call_op(body: "  ") }
  end

  should "deny a manager editing the assessee's comment (author-only)" do
    mgr_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      manager = create(:person, tenant: @tenant, email: mgr_user.email, name: "Boss")
      tu = create(:tenant_user, tenant: @tenant, user: mgr_user, person: manager, role: :member)
      @person.update!(manager: manager)
      ctx = AuthorizationContext.new(user: mgr_user, tenant_user: tu, person: manager)
      assert_raises(Pundit::NotAuthorizedError) { call_op(context: ctx) }
    end
  end
end

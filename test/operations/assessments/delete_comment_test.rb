# frozen_string_literal: true

require "test_helper"

# Covers deleting a comment over MCP: the soft-delete effect, author/admin
# authorisation, and the peer denial.
class Operations::Assessments::DeleteCommentTest < ActiveSupport::TestCase
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
        body: "To delete", author_id: @person.id)
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op(context: @context, **overrides)
    params = { assignment_id: @assignment.id, comment_id: @comment_id }.merge(overrides)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::DeleteComment.call(context: context, params: params)
    end
  end

  should "soft-delete the comment and report its status" do
    result = call_op(reason: "spam")
    assert_equal @comment_id, result[:comment_id]
    assert_equal "deleted", result[:status]

    reloaded = ActsAsTenant.with_tenant(@tenant) { PersonDevelopmentComment.find(@comment_id) }
    assert reloaded.deleted?
  end

  should "deny a peer who is not author or admin" do
    other_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      other = create(:person, tenant: @tenant, email: other_user.email)
      tu = create(:tenant_user, tenant: @tenant, user: other_user, person: other, role: :member)
      ctx = AuthorizationContext.new(user: other_user, tenant_user: tu, person: other)
      assert_raises(Pundit::NotAuthorizedError) { call_op(context: ctx) }
    end
  end
end

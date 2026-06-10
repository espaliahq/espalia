# frozen_string_literal: true

require "test_helper"

# Covers posting a comment over MCP: top-level + reply, validation (blank
# body, bad level, foreign capability), and the view-gated authorisation.
class Operations::Assessments::PostCommentTest < ActiveSupport::TestCase
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
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op(params, context: @context)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::PostComment.call(context: context, params: params)
    end
  end

  def base_params(**overrides)
    { assignment_id: @assignment.id, capability_stable_id: @cap.stable_id,
      level_ordinal: 2, body: "Nice work" }.merge(overrides)
  end

  should "post a top-level comment" do
    result = call_op(base_params)
    assert result[:comment_id].present?
    assert_equal "Nice work", result[:body]
    assert_equal 2, result[:level_ordinal]
    assert_nil result[:parent_id]

    stored = ActsAsTenant.with_tenant(@tenant) { PersonDevelopmentComment.find(result[:comment_id]) }
    assert_equal @person.id, stored.author_id
  end

  should "post a reply to an existing comment" do
    parent = call_op(base_params)
    reply = call_op(base_params(body: "Replying", parent_id: parent[:comment_id]))
    assert_equal parent[:comment_id], reply[:parent_id]
  end

  should "reject a blank body" do
    assert_raises(Operations::Base::ParameterError) { call_op(base_params(body: "   ")) }
  end

  should "reject a level the role does not have" do
    err = assert_raises(Operations::Base::ParameterError) { call_op(base_params(level_ordinal: 99)) }
    assert_match "level_ordinal", err.message
  end

  should "reject a capability outside the framework" do
    err = assert_raises(Operations::Base::ParameterError) do
      call_op(base_params(capability_stable_id: SecureRandom.uuid_v7))
    end
    assert_match "framework", err.message
  end

  should "deny a peer who cannot view the assessment" do
    other_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      other = create(:person, tenant: @tenant, email: other_user.email)
      tu = create(:tenant_user, tenant: @tenant, user: other_user, person: other, role: :member)
      ctx = AuthorizationContext.new(user: other_user, tenant_user: tu, person: other)
      assert_raises(Pundit::NotAuthorizedError) { call_op(base_params, context: ctx) }
    end
  end
end

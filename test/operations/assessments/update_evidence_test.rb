# frozen_string_literal: true

require "test_helper"

# Covers editing an existing evidence item over MCP: field replacement,
# author-only authorisation, the withdrawn-item guard, and validation.
class Operations::Assessments::UpdateEvidenceTest < ActiveSupport::TestCase
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

      @evidence_id = SecureRandom.uuid_v7
      @pd.record_evidence(@person.id, @framework_id, @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2,
        source: "self", evidence_type: "project_outcome",
        title: "Old", content: "Old body", author_id: @person.id)
    end
    @context = AuthorizationContext.new(user: @user, tenant_user: @tenant_user, person: @person)
  end

  def call_op(params, context: @context)
    ActsAsTenant.with_tenant(@tenant) do
      Operations::Assessments::UpdateEvidence.call(context: context, params: params)
    end
  end

  def base_params(**overrides)
    { assignment_id: @assignment.id, evidence_id: @evidence_id,
      evidence_type: "code_review", content: "New body", title: "New" }.merge(overrides)
  end

  should "replace the editable fields and stamp edited_at" do
    result = call_op(base_params)
    assert_equal "code_review", result[:evidence_type]
    assert_equal "New", result[:title]
    assert_equal "New body", result[:content]
    assert result[:edited_at].present?

    reloaded = ActsAsTenant.with_tenant(@tenant) { EvidenceItem.find(@evidence_id) }
    assert_equal "New body", reloaded.content
    assert_equal @person.id, reloaded.edited_by_id
  end

  should "require custom_type_label when evidence_type is other" do
    err = assert_raises(Operations::Base::ParameterError) do
      call_op(base_params(evidence_type: "other"))
    end
    assert_match "custom_type_label", err.message
  end

  should "reject an unsafe external_reference url" do
    assert_raises(Operations::Base::ParameterError) do
      call_op(base_params(external_reference: { "url" => "javascript:alert(1)" }))
    end
  end

  # Regression: an unknown key used to raise ActiveModel::UnknownAttributeError
  # → -32603 internal error at the MCP boundary; must now be a ParameterError.
  should "reject an external_reference with an unknown field as a ParameterError" do
    err = assert_raises(Operations::Base::ParameterError) do
      call_op(base_params(external_reference: { "url" => "https://x.test", "title" => "x" }))
    end
    assert_match(/unknown field/, err.message)
    assert_match(/title/, err.message)
  end

  should "deny a non-author (manager can withdraw but not edit another's words)" do
    mgr_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      manager = create(:person, tenant: @tenant, email: mgr_user.email, name: "Boss")
      tu = create(:tenant_user, tenant: @tenant, user: mgr_user, person: manager, role: :member)
      @person.update!(manager: manager)
      ctx = AuthorizationContext.new(user: mgr_user, tenant_user: tu, person: manager)
      assert_raises(Pundit::NotAuthorizedError) { call_op(base_params, context: ctx) }
    end
  end

  should "reject editing a withdrawn item" do
    ActsAsTenant.with_tenant(@tenant) do
      @pd.withdraw_evidence(@person.id, @framework_id, @evidence_id, withdrawn_by_id: @person.id)
    end
    assert_raises(Pundit::NotAuthorizedError) { call_op(base_params) }
  end
end

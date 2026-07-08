# frozen_string_literal: true

require "test_helper"

# An active manager-rating delegate must see the report's evidence and comments
# (they review like a manager). Regression for the report that delegates saw an
# empty/missing evidence + comment surface.
class Assessments::DelegateVisibilityTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @manager_user = create(:user, password: "password123")
    @delegate_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Mgr")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)
      @delegate = create(:person, tenant: @tenant, email: @delegate_user.email, name: "Delegate")
      create(:tenant_user, tenant: @tenant, user: @delegate_user, person: @delegate)
      @report = create(:person, tenant: @tenant, name: "Report", manager: @manager)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Eng Growth")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation, capability_id: cap.capability_id, level_ordinal: 2, description: "x")

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@report.id, framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.for_person(@report.id).first

      # Evidence authored by the report (NOT the delegate) — only visible if the
      # delegate is treated as sees-all.
      handler.record_evidence(@report.id, framework_id, SecureRandom.uuid_v7,
        capability_stable_id: cap.stable_id, level_ordinal: 2, source: "self",
        evidence_type: "project_outcome", content: "Shipped the payments revamp.",
        author_id: @report.id, title: "Payments revamp", valence: "demonstrated")

      create(:manager_assessment_delegation, tenant: @tenant, person_id: @report.id,
        framework_id: framework_id, delegate_person_id: @delegate.id, granted_by_id: @manager.id)
    end
  end

  should "show the report's evidence to the delegate in the activity feed" do
    sign_in @delegate_user
    get assessment_activity_path(@assignment)
    assert_response :success
    assert_match "Payments revamp", response.body
  end

  should "let the delegate open the assessment (manager view)" do
    sign_in @delegate_user
    get assessment_path(@assignment)
    assert_response :success
    assert_match "Report", response.body
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

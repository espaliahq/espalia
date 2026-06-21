# frozen_string_literal: true

require "test_helper"

class EvidenceModalControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @author_user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Mgr")
      @author = create(:person, tenant: @tenant, email: @author_user.email, name: "Author", manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @author_user, person: @author, role: :member)
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)

      @framework_id = SecureRandom.uuid_v7
      create(:framework_state, framework_id: @framework_id, name: "Eng")
      rf = create(:framework_role_family, framework_id: @framework_id, name: "Eng")
      role = create(:framework_role, role_family_id: rf.role_family_id, name: "SWE", code: "E", track: "ic")
      level = create(:framework_level, role_id: role.role_id, ordinal: 2, title: "Mid", code: "E2")
      cat = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: role.role_id, weight: 1.0)
      exp = create(:framework_behavioural_expectation, capability_id: @cap.capability_id, level_ordinal: 2,
                   description: "Weighs options and explains reasoning")
      create(:framework_role_illustration, expectation_id: exp.expectation_id, role_id: role.role_id, ordinal: 1,
             description: "Wrote the migration RFC")

      handler = PersonDevelopment::CommandHandler.new
      handler.assign_to_framework(@author.id, @framework_id, role.role_id, level.level_id)
      @assignment = PersonFrameworkAssignment.find_by(person_id: @author.id, framework_id: @framework_id)
      @evidence_id = SecureRandom.uuid_v7
      handler.record_evidence(@author.id, @framework_id, @evidence_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2, source: "self",
        evidence_type: "project_outcome", title: "RFC", content: "Original", author_id: @author.id)
    end
  end

  context "GET /evidence_modal mode=new" do
    should "render the form with the primary-cell expectation + examples" do
      sign_in @author_user
      get evidence_modal_path(mode: "new", assignment_id: @assignment.id,
                              capability_stable_id: @cap.stable_id, level_ordinal: 2, return_to: "assessment:#{@assignment.id}")
      assert_response :success
      assert_match "Critical Thinking · Level 2", response.body
      assert_match "Weighs options and explains reasoning", response.body
      assert_match "Wrote the migration RFC", response.body
      assert_select "turbo-frame#evidence-modal"
      assert_select "select[name='evidence[evidence_type]']:not([disabled])"
      # No role/level chrome line when opened within an assessment.
      assert_no_match(/on Author/, response.body)
    end
  end

  context "GET /evidence_modal mode=edit" do
    should "prefill content for the author (editable)" do
      sign_in @author_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "assessment:#{@assignment.id}")
      assert_response :success
      assert_match "Original", response.body
      assert_select "textarea[name='evidence[content]']:not([disabled])"
    end

    should "disable content for a non-author who may only link (manager)" do
      sign_in @manager_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "assessment:#{@assignment.id}")
      assert_response :success
      assert_select "textarea[name='evidence[content]'][disabled]"
      assert_match(/only where it applies/i, response.body)
    end

    should "show the role/level line when opened from the hub" do
      sign_in @author_user
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "hub")
      assert_response :success
      assert_match(/on Author/, response.body)
    end
  end

  context "permissions" do
    should "forbid an unrelated user from editing" do
      other = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: other, person: create(:person, tenant: @tenant), role: :member) }
      sign_in other
      get evidence_modal_path(mode: "edit", evidence_id: @evidence_id, return_to: "hub")
      assert_response :forbidden
    end
  end
end

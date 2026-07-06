# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::AttainmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @framework_id = SecureRandom.uuid_v7
      family = create(:framework_role_family, framework_id: @framework_id, name: "Engineering")
      @role = create(:framework_role, name: "Engineer", role_family_id: family.role_family_id)
      (1..3).each { |ordinal| create(:framework_level, role_id: @role.role_id, ordinal: ordinal, code: "E#{ordinal}") }
      category = create(:framework_capability_category, framework_id: @framework_id, name: "Thinking")
      @cap = create(:framework_capability, category_id: category.category_id, name: "Strategic Thinking")
      create(:framework_capability_role_binding, capability_id: @cap.capability_id, role_id: @role.role_id)

      @cycle = create(:assessment_cycle, tenant: @tenant, name: "Q1 2026",
        framework_id: @framework_id, status: "open")

      # A manager with one enrolled, fully-rated report.
      @manager_user = create(:user, password: "password123")
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report = create(:person, tenant: @tenant, name: "Report One", manager: @manager)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
        person_id: @report.id, role_id: @role.role_id, level_ordinal: 2, status: "enrolled")
      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
        person_id: @report.id, framework_id: @framework_id,
        capability_stable_id: @cap.stable_id, level_ordinal: 2,
        self_rated_frequency: "consistent")

      @admin_user = create(:user, password: "password123")
      admin = create(:person, tenant: @tenant, email: @admin_user.email, name: "Admin")
      create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)

      @outsider_user = create(:user, password: "password123")
      outsider = create(:person, tenant: @tenant, email: @outsider_user.email, name: "Outsider")
      create(:tenant_user, tenant: @tenant, user: @outsider_user, person: outsider, role: :member)
    end
  end

  context "GET /assessment_cycles/:id/attainment" do
    should "render unsuppressed values for an admin" do
      sign_in @admin_user
      get attainment_assessment_cycle_path(@cycle)

      assert_response :success
      assert_includes response.body, "capability attainment"
      assert_includes response.body, "Strategic Thinking"
      assert_includes response.body, "100%"
      assert_includes response.body, "1/1 assessed"
    end

    should "render unsuppressed values for a subtree-scoped manager" do
      sign_in @manager_user
      get attainment_assessment_cycle_path(@cycle)

      assert_response :success
      assert_includes response.body, "Strategic Thinking"
      # The manager chain can open every assessment in its subtree, so the
      # aggregate discloses nothing new — no small-cohort floor applies.
      assert_includes response.body, "100%"
      assert_includes response.body, "1/1 assessed"
      assert_not_includes response.body, "n = 1"
    end

    should "honour the perspective param" do
      sign_in @admin_user
      get attainment_assessment_cycle_path(@cycle, perspective: "manager")

      assert_response :success
      # No manager ratings exist → the only participant is unassessed.
      assert_includes response.body, "0/1 assessed"
      assert_includes response.body, "0%"
    end

    should "fall back to the effective perspective on an unknown param" do
      sign_in @admin_user
      get attainment_assessment_cycle_path(@cycle, perspective: "bogus")

      assert_response :success
      assert_includes response.body, "100%"
    end

    should "render the family axis" do
      sign_in @admin_user
      get attainment_assessment_cycle_path(@cycle, by: "family")

      assert_response :success
      assert_includes response.body, "Engineering"
    end

    should "deny a member with no reports in the cycle" do
      sign_in @outsider_user
      get attainment_assessment_cycle_path(@cycle)

      assert_response :redirect
    end

    should "redirect unauthenticated users to sign in" do
      get attainment_assessment_cycle_path(@cycle)
      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

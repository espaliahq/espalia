# frozen_string_literal: true

require "test_helper"

class AssessmentCycles::CohortsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @framework_id = SecureRandom.uuid_v7
      @role = create(:framework_role, name: "Engineer")
      category = create(:framework_capability_category, framework_id: @framework_id)
      cap = create(:framework_capability, category_id: category.category_id)
      create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: @role.role_id)

      @cycle = create(:assessment_cycle, tenant: @tenant, name: "Q1 2026",
        framework_id: @framework_id, status: "open")

      # A manager with one enrolled report.
      @manager_user = create(:user, password: "password123")
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager, role: :member)
      @report = create(:person, tenant: @tenant, name: "Report One", manager: @manager)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
        person_id: @report.id, role_id: @role.role_id, level_ordinal: 2, status: "enrolled")
      create(:assessment_cycle_progress, tenant: @tenant, cycle: @cycle,
        person_id: @report.id, status: "started")

      @admin_user = create(:user, password: "password123")
      admin = create(:person, tenant: @tenant, email: @admin_user.email, name: "Admin")
      create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)

      @outsider_user = create(:user, password: "password123")
      outsider = create(:person, tenant: @tenant, email: @outsider_user.email, name: "Outsider")
      create(:tenant_user, tenant: @tenant, user: @outsider_user, person: outsider, role: :member)
    end
  end

  context "GET /assessment_cycles/:id/cohort" do
    should "render the cohort view for a manager scoped to their subtree" do
      sign_in @manager_user
      get cohort_assessment_cycle_path(@cycle)

      assert_response :success
      assert_includes response.body, "cohort progress"
      assert_includes response.body, "Progress funnel"
      assert_includes response.body, "Report One"
    end

    should "render the cohort view for an admin" do
      sign_in @admin_user
      get cohort_assessment_cycle_path(@cycle)

      assert_response :success
      assert_includes response.body, "Report One"
    end

    should "honour the role pivot" do
      sign_in @admin_user
      get cohort_assessment_cycle_path(@cycle, pivot: "role")

      assert_response :success
      assert_includes response.body, "Engineer"
    end

    should "deny a member with no reports in the cycle" do
      sign_in @outsider_user
      get cohort_assessment_cycle_path(@cycle)

      assert_response :redirect
    end

    should "redirect unauthenticated users to sign in" do
      get cohort_assessment_cycle_path(@cycle)
      assert_redirected_to new_user_session_path
    end
  end

  context "viewer scope" do
    should "default an admin to the whole cycle" do
      sign_in @admin_user
      get cohort_assessment_cycle_path(@cycle)

      assert_response :success
      assert_includes response.body, "Report One"
    end

    should "narrow an admin to their own subtree with ?scope=mine" do
      # The admin manages nobody here, so their subtree is empty — proving the
      # param flipped the scope (the whole-cycle participant drops out).
      sign_in @admin_user
      get cohort_assessment_cycle_path(@cycle, scope: "mine")

      assert_response :success
      assert_not_includes response.body, "Report One"
    end
  end

  context "while impersonating (admin's global privileges must not leak)" do
    should "deny the cohort when impersonating a plain member with no reports" do
      sign_in @admin_user
      impersonate(@outsider_user)

      get cohort_assessment_cycle_path(@cycle)
      # As the member, not the admin: no reports in the cycle → denied.
      assert_response :redirect
    end

    should "scope to the impersonated manager's subtree, not the whole cycle" do
      sign_in @admin_user
      impersonate(@manager_user)

      get cohort_assessment_cycle_path(@cycle)
      assert_response :success
      assert_includes response.body, "Report One"
    end
  end

  private

  def impersonate(user)
    tenant_user = ActsAsTenant.with_tenant(@tenant) { TenantUser.find_by(user_id: user.id) }
    post impersonation_path, params: { tenant_user_id: tenant_user.id }
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

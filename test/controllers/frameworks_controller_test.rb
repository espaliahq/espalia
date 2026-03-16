# frozen_string_literal: true

require "test_helper"

class FrameworksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @user)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")

      # Create role family with IC and management roles
      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @ic_role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      create(:framework_level, role_id: @ic_role.role_id, ordinal: 1, title: "E1", code: "E1")

      @mgmt_role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Eng Manager", code: "EM", track: "management")
      create(:framework_level, role_id: @mgmt_role.role_id, ordinal: 1, title: "EM1", code: "EM1")

      # Create capability with binding and expectation
      cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      cap = create(:framework_capability, category_id: cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding, capability_id: cap.capability_id, role_id: @ic_role.role_id)
      create(:framework_behavioural_expectation,
        capability_id: cap.capability_id, level_ordinal: 1, description: "Asks good questions")
    end
  end

  context "GET /frameworks" do
    should "render the index page with frameworks" do
      sign_in @user
      get frameworks_path

      assert_response :success
      assert_includes response.body, "Engineering Growth"
      assert_includes response.body, "Frameworks"
    end

    should "redirect unauthenticated users to sign in" do
      get frameworks_path

      assert_redirected_to new_user_session_path
    end
  end

  context "GET /frameworks/:id" do
    should "render the show page for a valid framework" do
      sign_in @user
      get framework_path(@framework.framework_id)

      assert_response :success
      assert_includes response.body, "Engineering Growth"
      assert_includes response.body, "turbo-frame"
    end

    should "render with role params filtering" do
      sign_in @user
      get framework_path(@framework.framework_id, roles: [ @ic_role.role_id ])

      assert_response :success
      assert_includes response.body, "Critical Thinking"
    end

    should "redirect to index for an invalid framework_id" do
      sign_in @user
      get framework_path("nonexistent-id")

      assert_redirected_to frameworks_path
    end

    should "redirect unauthenticated users to sign in" do
      get framework_path(@framework.framework_id)

      assert_redirected_to new_user_session_path
    end
  end

  context "GET /frameworks/:id/matrix" do
    should "render Turbo Frame without layout" do
      sign_in @user
      get matrix_framework_path(@framework.framework_id, roles: [ @ic_role.role_id ])

      assert_response :success
      assert_includes response.body, "turbo-frame"
      assert_not_includes response.body, "<html"
    end

    should "filter by track" do
      sign_in @user
      get matrix_framework_path(@framework.framework_id, track: "management")

      assert_response :success
      # Management role has no bindings, so no capabilities shown
      assert_includes response.body, "turbo-frame"
    end

    should "render empty state with no matching roles" do
      sign_in @user
      get matrix_framework_path(@framework.framework_id, roles: [ "nonexistent" ])

      assert_response :success
      assert_includes response.body, "Select roles"
    end

    should "redirect unauthenticated users to sign in" do
      get matrix_framework_path(@framework.framework_id)

      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

# frozen_string_literal: true

require "test_helper"

class FrameworksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @user)
      @framework = create(:framework_state, name: "Engineering Growth")
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

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

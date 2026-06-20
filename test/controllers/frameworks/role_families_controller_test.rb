# frozen_string_literal: true

require "test_helper"

class Frameworks::RoleFamiliesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @rf_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, @rf_id, "Engineering")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "PATCH /frameworks/:framework_id/role_families/:id" do
    should "rename the role family and return the re-rendered name frame" do
      sign_in @user
      patch framework_role_family_path(framework_id: @framework_id, id: @rf_id),
            params: { role_family: { name: "Platform Engineering" } }

      assert_response :success
      assert_includes response.body, "role-family-name-#{@rf_id}"
      assert_includes response.body, "Platform Engineering"

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "Platform Engineering",
                     FrameworkState::RoleFamily.find_by(role_family_id: @rf_id).name
      end
    end

    should "return unprocessable when the name is blank" do
      sign_in @user
      patch framework_role_family_path(framework_id: @framework_id, id: @rf_id),
            params: { role_family: { name: "" } }

      assert_response :unprocessable_content
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      patch framework_role_family_path(framework_id: @framework_id, id: @rf_id),
            params: { role_family: { name: "blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

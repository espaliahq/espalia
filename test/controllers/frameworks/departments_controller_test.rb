# frozen_string_literal: true

require "test_helper"

class Frameworks::DepartmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @fc_id = SecureRandom.uuid_v7
      @fo_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Org")
      handler.add_role_family(@framework_id, @fc_id, "Financial Control", department: "Finance")
      handler.add_role_family(@framework_id, @fo_id, "Finance Operations", department: "Finance")
      handler.add_role(@framework_id, SecureRandom.uuid_v7, @fc_id, "Controller", "FC", "ic")
      handler.add_role(@framework_id, SecureRandom.uuid_v7, @fo_id, "Ops", "FO", "ic")
      handler.publish_version(@framework_id, "test")
    end
  end

  def department_of(role_family_id)
    ActsAsTenant.with_tenant(@tenant) do
      FrameworkState::RoleFamily.find_by(role_family_id: role_family_id).department
    end
  end

  context "PATCH /frameworks/:framework_id/departments" do
    should "rename the department across all its families and re-render the tree" do
      sign_in @user
      patch framework_departments_path(framework_id: @framework_id),
            params: { department: { from: "Finance", to: "Commercial Finance" } },
            headers: { "Turbo-Frame" => "role-tree-families" }

      assert_response :success
      assert_includes response.body, "role-tree-families"
      assert_includes response.body, "Commercial Finance"

      assert_equal "Commercial Finance", department_of(@fc_id)
      assert_equal "Commercial Finance", department_of(@fo_id)
    end

    should "return unprocessable when renaming to the same name" do
      sign_in @user
      patch framework_departments_path(framework_id: @framework_id),
            params: { department: { from: "Finance", to: "Finance" } }

      assert_response :unprocessable_content
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      patch framework_departments_path(framework_id: @framework_id),
            params: { department: { from: "Finance", to: "Blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
      assert_equal "Finance", department_of(@fc_id)
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

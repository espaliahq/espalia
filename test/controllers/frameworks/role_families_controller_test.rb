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
      @role_id = SecureRandom.uuid_v7
      @role_id2 = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, @rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, @rf_id, "Engineer", "E", "ic")
      handler.add_role(@framework_id, @role_id2, @rf_id, "Staff Engineer", "SE", "ic")
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

    # A bodyless 422 inside a frame is invisible (Hard-Won Lesson 26).
    should "re-render the name frame at 422 with the error and the typed text" do
      sign_in @user
      patch framework_role_family_path(framework_id: @framework_id, id: @rf_id),
            params: { role_family: { name: "   " } }

      assert_response :unprocessable_content
      assert_select "turbo-frame#role-family-name-#{@rf_id}" do
        assert_select "[data-editor-error='the name can’t be blank'][data-editor-value='   ']"
        assert_select "[role=alert]", text: "Couldn’t save: the name can’t be blank"
      end
    end

    should "move the family between departments and re-render the families frame" do
      sign_in @user
      patch framework_role_family_path(framework_id: @framework_id, id: @rf_id),
            params: { role_family: { name: "Engineering", department: "Product + Engineering" } },
            headers: { "Turbo-Frame" => "role-tree-families" }

      assert_response :success
      # The families-frame response carries the frame + the new department header,
      # not the per-family name frame.
      assert_includes response.body, "role-tree-families"
      assert_includes response.body, "Product + Engineering"

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "Product + Engineering",
                     FrameworkState::RoleFamily.find_by(role_family_id: @rf_id).department
      end
    end

    should "thread the selection through so only the selected role stays checked" do
      sign_in @user
      patch framework_role_family_path(framework_id: @framework_id, id: @rf_id),
            params: { role_family: { department: "Finance" }, roles: [ @role_id ], track: "both" },
            headers: { "Turbo-Frame" => "role-tree-families" }

      assert_response :success
      # The selected role's checkbox is checked; the unselected one is not — so a
      # dropped `roles[]` (which would default to all-checked) fails the test.
      assert_select "input[data-role-id=?][checked]", @role_id
      assert_select "input[data-role-id=?]:not([checked])", @role_id2
    end

    should "leave the department unchanged when an unrelated field is edited" do
      ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::RoleFamily.find_by(role_family_id: @rf_id).update_column(:department, "Finance")
      end

      sign_in @user
      # department key absent → department is untouched (not cleared to nil).
      patch framework_role_family_path(framework_id: @framework_id, id: @rf_id),
            params: { role_family: { name: "Renamed" } }

      assert_response :success
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "Finance", FrameworkState::RoleFamily.find_by(role_family_id: @rf_id).department
      end
    end

    should "404 on an unknown role family id (not a masked 422)" do
      sign_in @user
      patch framework_role_family_path(framework_id: @framework_id, id: SecureRandom.uuid_v7),
            params: { role_family: { name: "Whatever" } }

      assert_response :not_found
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

  context "POST /frameworks/:framework_id/role_families" do
    should "create the family and re-render the families frame with it ghost-wiggled" do
      sign_in @user
      post framework_role_families_path(framework_id: @framework_id),
           params: { role_family: { name: "Design", department: "Product + Design" } }

      assert_response :success
      assert_includes response.body, "role-tree-families"
      assert_includes response.body, "Design"
      assert_includes response.body, "Product + Design"
      # No roles yet → the new family renders as a ghost with the wiggle.
      assert_includes response.body, "No roles yet"

      ActsAsTenant.with_tenant(@tenant) do
        family = FrameworkState::RoleFamily.find_by(framework_id: @framework_id, name: "Design")
        assert family
        assert_equal "Product + Design", family.department
      end
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      post framework_role_families_path(framework_id: @framework_id),
           params: { role_family: { name: "Blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
      ActsAsTenant.with_tenant(@tenant) do
        assert_nil FrameworkState::RoleFamily.find_by(framework_id: @framework_id, name: "Blocked")
      end
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

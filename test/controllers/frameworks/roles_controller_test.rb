# frozen_string_literal: true

require "test_helper"

class Frameworks::RolesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @rf_id = rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "PATCH /frameworks/:framework_id/roles/:id" do
    should "rename the role and return the re-rendered name frame" do
      sign_in @user
      patch framework_role_path(framework_id: @framework_id, id: @role_id),
            params: { role: { name: "Backend Engineer" } }

      assert_response :success
      assert_includes response.body, "role-name-#{@role_id}"
      assert_includes response.body, "Backend Engineer"

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "Backend Engineer", FrameworkState::Role.find_by(role_id: @role_id).name
      end
    end

    # A bodyless 422 inside a frame is invisible (Hard-Won Lesson 26).
    should "re-render the name frame at 422 with the error and the typed text" do
      sign_in @user
      patch framework_role_path(framework_id: @framework_id, id: @role_id),
            params: { role: { name: "   " } }

      assert_response :unprocessable_content
      assert_select "turbo-frame#role-name-#{@role_id}" do
        assert_select "[data-editor-error='the name can’t be blank'][data-editor-value='   ']"
        assert_select "[role=alert]", text: "Couldn’t save: the name can’t be blank"
      end
    end

    should "404 on an unknown role id (not a masked 422)" do
      sign_in @user
      patch framework_role_path(framework_id: @framework_id, id: SecureRandom.uuid_v7),
            params: { role: { name: "Whatever" } }

      assert_response :not_found
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      patch framework_role_path(framework_id: @framework_id, id: @role_id),
            params: { role: { name: "blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  context "PATCH via the edit dialog (role-tree-families frame)" do
    should "update code and track and re-render the families frame" do
      sign_in @user
      patch framework_role_path(framework_id: @framework_id, id: @role_id),
            params: { role: { name: "Software Engineer", code: "SE", track: "management" },
                      roles: [ @role_id ], track: "both" },
            headers: { "Turbo-Frame" => "role-tree-families" }

      assert_response :success
      assert_includes response.body, "role-tree-families"

      ActsAsTenant.with_tenant(@tenant) do
        role = FrameworkState::Role.find_by(role_id: @role_id)
        assert_equal "SE", role.code
        assert_equal "management", role.track
        assert_equal "Software Engineer", role.name
      end
    end

    should "forward only changed fields (unchanged name emits no rename)" do
      sign_in @user
      patch framework_role_path(framework_id: @framework_id, id: @role_id),
            params: { role: { name: "Software Engineer", code: "E", track: "ic" } },
            headers: { "Turbo-Frame" => "role-tree-families" }

      assert_response :success
      # Nothing changed → no event appended beyond the seed history.
      events = Rails.configuration.event_store
        .read.stream("tenant-#{@tenant.id}/Framework-#{@framework_id}").to_a
      assert_empty events.select { |e| e.is_a?(Frameworks::Events::RoleUpdated) }
    end

    should "exclude unchanged fields from the update event when one field changes" do
      sign_in @user
      patch framework_role_path(framework_id: @framework_id, id: @role_id),
            params: { role: { name: "Software Engineer", code: "SE", track: "ic" } },
            headers: { "Turbo-Frame" => "role-tree-families" }

      assert_response :success
      updates = Rails.configuration.event_store
        .read.stream("tenant-#{@tenant.id}/Framework-#{@framework_id}").to_a
        .select { |e| e.is_a?(Frameworks::Events::RoleUpdated) }
      assert_equal 1, updates.size
      # Only the changed field rides the (compacted) event — the feed reads
      # present keys as "what changed".
      assert_equal "SE", updates.first.data[:code]
      assert_not updates.first.data.key?(:name)
      assert_not updates.first.data.key?(:track)

      ActsAsTenant.with_tenant(@tenant) do
        role = FrameworkState::Role.find_by(role_id: @role_id)
        assert_equal "SE", role.code
        assert_equal "Software Engineer", role.name
      end
    end
  end

  context "POST /frameworks/:framework_id/roles" do
    should "create the role and re-render the families frame with it ghost-wiggled" do
      sign_in @user
      post framework_roles_path(framework_id: @framework_id),
           params: { role: { role_family_id: @rf_id, name: "Engineering Manager",
                             code: "EM", track: "management" } }

      assert_response :success
      assert_includes response.body, "role-tree-families"
      assert_includes response.body, "Engineering Manager"
      # No published levels yet → wiggled ghost in the tree.
      assert_includes response.body, "Not in the published framework yet"

      ActsAsTenant.with_tenant(@tenant) do
        role = FrameworkState::Role.find_by(role_family_id: @rf_id, name: "Engineering Manager")
        assert role
        assert_equal "management", role.track
      end
    end

    should "return unprocessable for a family outside this framework" do
      sign_in @user
      post framework_roles_path(framework_id: @framework_id),
           params: { role: { role_family_id: SecureRandom.uuid_v7, name: "X", code: "X", track: "ic" } }

      assert_response :unprocessable_content
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      post framework_roles_path(framework_id: @framework_id),
           params: { role: { role_family_id: @rf_id, name: "Blocked", code: "B", track: "ic" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

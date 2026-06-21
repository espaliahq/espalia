# frozen_string_literal: true

require "test_helper"

class Frameworks::LevelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rf_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      @level_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, role_id, rf_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, @level_id, role_id, 1, "Software Engineer I", "E1")
      handler.publish_version(@framework_id, "test")
    end
  end

  context "PATCH /frameworks/:framework_id/levels/:id" do
    should "rename the level title and return the re-rendered title frame" do
      sign_in @user
      patch framework_level_path(framework_id: @framework_id, id: @level_id),
            params: { level: { title: "Engineer I" } }

      assert_response :success
      assert_includes response.body, "level-title-#{@level_id}"
      assert_includes response.body, "Engineer I"

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal "Engineer I", FrameworkState::Level.find_by(level_id: @level_id).title
      end
    end

    should "return unprocessable when the title is blank" do
      sign_in @user
      patch framework_level_path(framework_id: @framework_id, id: @level_id),
            params: { level: { title: "" } }

      assert_response :unprocessable_content
    end

    should "404 on an unknown level id (not a masked 422)" do
      sign_in @user
      patch framework_level_path(framework_id: @framework_id, id: SecureRandom.uuid_v7),
            params: { level: { title: "Whatever" } }

      assert_response :not_found
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer

      patch framework_level_path(framework_id: @framework_id, id: @level_id),
            params: { level: { title: "blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

# frozen_string_literal: true

require "test_helper"

class Frameworks::NamesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @owner_user = create(:user, password: "password123")
    @editor_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: @owner_person)
      @editor_person = create(:person, tenant: @tenant, email: @editor_user.email)
      create(:tenant_user, tenant: @tenant, user: @editor_user, role: :member, person: @editor_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework", created_by: @owner_person.id)
      handler.publish_version(@framework_id, "test")
      create(:framework_collaborator, tenant: @tenant, framework_id: @framework_id,
                                      person_id: @editor_person.id, role: "editor")
    end
  end

  def framework_name
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by(framework_id: @framework_id).name }
  end

  def rename(name)
    patch framework_name_path(framework_id: @framework_id), params: { framework: { name: name } }
  end

  context "PATCH /frameworks/:framework_id/name" do
    should "rename the framework and return the re-rendered name frame, pencil intact" do
      sign_in @admin_user
      rename("Engineering Career Path")

      assert_response :success
      assert_includes response.body, "framework-name-#{@framework_id}"
      assert_includes response.body, "Engineering Career Path"
      assert_includes response.body, "Edit framework name", "the response must keep the pencil (Lesson 13)"
      assert_equal "Engineering Career Path", framework_name
    end

    should "let the framework owner rename without tenant admin rights" do
      sign_in @owner_user
      rename("Owner Renamed")

      assert_response :success
      assert_equal "Owner Renamed", framework_name
    end

    should "answer a blank name with 422 AND the frame carrying the error + attempted value" do
      sign_in @admin_user
      rename("   ")

      assert_response :unprocessable_content
      assert_includes response.body, "framework-name-#{@framework_id}"
      assert_includes response.body, "data-editor-error"
      assert_includes response.body, "can’t be blank"
      assert_includes response.body, 'data-editor-value="   "', "the attempted text must be echoed back"
      assert_equal "Test Framework", framework_name
    end

    should "404 on an unknown framework" do
      sign_in @admin_user
      patch framework_name_path(framework_id: SecureRandom.uuid_v7), params: { framework: { name: "X" } }

      assert_response :not_found
    end

    should "deny an editor collaborator" do
      sign_in @editor_user
      rename("blocked")

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
      assert_equal "Test Framework", framework_name
    end

    should "deny a plain tenant member" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: viewer, role: :member) }
      sign_in viewer
      rename("blocked")

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  context "GET /frameworks/:id/edit" do
    should "render the rename pencil for an admin" do
      sign_in @admin_user
      get edit_framework_path(@framework_id)

      assert_response :success
      assert_includes response.body, "Edit framework name"
    end

    should "render no rename pencil for an editor" do
      sign_in @editor_user
      get edit_framework_path(@framework_id)

      assert_response :success
      assert_includes response.body, "Test Framework"
      assert_not_includes response.body, "Edit framework name"
    end

    should "render no rename pencil in view mode even for an admin" do
      sign_in @admin_user
      get framework_path(@framework_id)

      assert_response :success
      assert_not_includes response.body, "Edit framework name"
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

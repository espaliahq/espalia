# frozen_string_literal: true

require "test_helper"

class Frameworks::CollaboratorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user   = create(:user, password: "password123")
    @owner_user   = create(:user, password: "password123")
    @member_user  = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person  = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                            person: @admin_person)

      @owner_person  = create(:person, tenant: @tenant, email: @owner_user.email)
      create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member,
                            person: @owner_person)

      @member_person = create(:person, tenant: @tenant, email: @member_user.email)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member,
                            person: @member_person)

      @target_person = create(:person, tenant: @tenant, name: "Target Person",
                                        email: "target@example.com")

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, SecureRandom.uuid_v7, rfid, "Software Engineer", "E", "ic")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner",
                                added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "test")
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "GET index renders the collaborators frame" do
      get framework_collaborators_path(@framework_id)
      assert_response :success
      assert_includes response.body, "framework-collaborators"
      assert_includes response.body, @owner_person.name
    end

    should "POST adds a collaborator" do
      post framework_collaborators_path(@framework_id),
           params: { collaborator: { person_id: @target_person.id, role: "editor",
                                     scope_type: "", scope_id: "" } }
      assert_redirected_to framework_settings_path(@framework_id)
      ActsAsTenant.with_tenant(@tenant) do
        assert FrameworkState::Collaborator.exists?(
          framework_id: @framework_id, person_id: @target_person.id, role: "editor"
        )
      end
    end
  end

  context "as a framework owner (not a tenant admin)" do
    setup { sign_in @owner_user }

    should "GET index renders" do
      get framework_collaborators_path(@framework_id)
      assert_response :success
    end

    should "POST adds a collaborator" do
      post framework_collaborators_path(@framework_id),
           params: { collaborator: { person_id: @target_person.id, role: "viewer" } }
      assert_redirected_to framework_settings_path(@framework_id)
      ActsAsTenant.with_tenant(@tenant) do
        assert FrameworkState::Collaborator.exists?(
          framework_id: @framework_id, person_id: @target_person.id, role: "viewer"
        )
      end
    end

    should "GET scope_picker returns the role select" do
      get scope_picker_framework_collaborators_path(@framework_id),
          params: { role: "role_lead" }
      assert_response :success
      assert_includes response.body, "Software Engineer"
    end
  end

  context "as a tenant member with no collaborator role" do
    setup { sign_in @member_user }

    should "deny GET index" do
      get framework_collaborators_path(@framework_id)
      assert_redirected_to root_path
    end

    should "deny POST" do
      post framework_collaborators_path(@framework_id),
           params: { collaborator: { person_id: @target_person.id, role: "viewer" } }
      assert_redirected_to root_path
    end

    should "deny scope_picker GET" do
      get scope_picker_framework_collaborators_path(@framework_id),
          params: { role: "role_lead" }
      assert_redirected_to root_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

# frozen_string_literal: true

require "test_helper"

class Tenant::Users::CollaboratorsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user  = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                            person: @admin_person)

      @member_person = create(:person, tenant: @tenant, email: @member_user.email)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user,
                                         role: :member, person: @member_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_collaborator(@framework_id, @admin_person.id.to_s, "owner",
                                added_by: @admin_person.id.to_s)
      handler.publish_version(@framework_id, "test")
    end
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    context "POST /tenant/users/:user_id/collaborators" do
      should "add a framework-wide editor role" do
        post tenant_user_collaborators_path(@member_tu),
             params: {
               collaborator: { framework_id: @framework_id, role: "editor",
                               scope_type: "", scope_id: "" }
             }
        assert_redirected_to tenant_user_path(@member_tu)
        ActsAsTenant.with_tenant(@tenant) do
          assert FrameworkState::Collaborator.exists?(
            framework_id: @framework_id, person_id: @member_person.id, role: "editor"
          )
        end
      end

      should "add a scoped role_lead with the chosen role scope" do
        post tenant_user_collaborators_path(@member_tu),
             params: {
               collaborator: { framework_id: @framework_id, role: "role_lead",
                               scope_type: "role", scope_id: @role_id }
             }
        assert_redirected_to tenant_user_path(@member_tu)
        ActsAsTenant.with_tenant(@tenant) do
          row = FrameworkState::Collaborator.find_by(
            framework_id: @framework_id, person_id: @member_person.id, role: "role_lead"
          )
          assert_not_nil row
          assert_equal "role", row.scope_type
          assert_equal @role_id, row.scope_id
        end
      end

      should "surface aggregate errors as a flash alert" do
        # Add the same role twice — aggregate raises "already has this role"
        post tenant_user_collaborators_path(@member_tu),
             params: { collaborator: { framework_id: @framework_id, role: "editor" } }
        post tenant_user_collaborators_path(@member_tu),
             params: { collaborator: { framework_id: @framework_id, role: "editor" } }
        follow_redirect!
        assert_includes response.body, "already has this role"
      end
    end

    context "DELETE /tenant/users/:user_id/collaborators/:id" do
      setup do
        ActsAsTenant.with_tenant(@tenant) do
          Frameworks::CommandHandler.new.add_collaborator(
            @framework_id, @member_person.id.to_s, "editor",
            added_by: @admin_person.id.to_s
          )
        end
      end

      should "remove the assignment" do
        composite = [ @framework_id, "editor", "", "" ].join(":")
        delete tenant_user_collaborator_path(@member_tu, composite)
        assert_redirected_to tenant_user_path(@member_tu)
        ActsAsTenant.with_tenant(@tenant) do
          assert_not FrameworkState::Collaborator.exists?(
            framework_id: @framework_id, person_id: @member_person.id, role: "editor"
          )
        end
      end
    end

    context "GET /tenant/users/:id/collaborator_scope_picker" do
      should "render the role-scope select for a scoped role" do
        get collaborator_scope_picker_tenant_user_path(@member_tu),
            params: { framework_id: @framework_id, role: "role_lead" }
        assert_response :success
        assert_includes response.body, "collaborator-scope-picker"
        assert_includes response.body, "Software Engineer"
      end

      should "render an empty fragment for framework-wide roles" do
        get collaborator_scope_picker_tenant_user_path(@member_tu),
            params: { framework_id: @framework_id, role: "editor" }
        assert_response :success
        # Empty fragment clears prior scope via hidden inputs — no <select> rendered
        assert_no_match(/<select[^>]*name="collaborator\[scope_id\]"/, response.body)
      end
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "deny POST" do
      post tenant_user_collaborators_path(@member_tu),
           params: { collaborator: { framework_id: @framework_id, role: "editor" } }
      assert_redirected_to root_path
      ActsAsTenant.with_tenant(@tenant) do
        assert_not FrameworkState::Collaborator.exists?(
          framework_id: @framework_id, person_id: @member_person.id, role: "editor"
        )
      end
    end

    should "deny scope picker GET" do
      get collaborator_scope_picker_tenant_user_path(@member_tu),
          params: { framework_id: @framework_id, role: "role_lead" }
      assert_redirected_to root_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

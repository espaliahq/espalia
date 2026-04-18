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

  context "view vs edit mode — pending-suggestion visual indicators" do
    setup do
      # Seed a pending edit on the capability so the decoration concern has
      # something to render. Admin user so /edit is accessible.
      @admin_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
        create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: admin_person)
        cap = FrameworkState::Capability.first
        create(:framework_suggested_edit,
               tenant: @tenant,
               framework_id: @framework.framework_id,
               target_entity_type: "capability",
               target_entity_id: cap.capability_id,
               field: "name",
               current_value: cap.name,
               suggested_value: "Renamed",
               author_id: admin_person.id,
               status: "pending")
      end
    end

    should "not render the wavy pending-edit underline in view mode" do
      sign_in @admin_user
      get framework_path(@framework.framework_id)

      assert_response :success
      assert_not_includes response.body, "decoration-wavy",
        "view mode should not leak pending-edit decorations into the grid"
    end

    should "render the wavy pending-edit underline in edit mode" do
      sign_in @admin_user
      get edit_framework_path(@framework.framework_id)

      assert_response :success
      assert_includes response.body, "decoration-wavy",
        "edit mode should surface pending-edit decorations"
    end
  end

  context "GET /frameworks/:id/edit" do
    should "redirect viewer (no collaborator role) with not-authorised flash" do
      sign_in @user
      get edit_framework_path(@framework.framework_id)

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end

    should "render 200 for a collaborator with suggest rights" do
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person, tenant: @tenant, email: @user.email)
        TenantUser.find_by(user: @user).update!(person: person)
        create(:framework_collaborator, tenant: @tenant,
               framework_id: @framework.framework_id, person_id: person.id,
               role: "collaborator")
      end

      sign_in @user
      get edit_framework_path(@framework.framework_id)

      assert_response :success
      assert_includes response.body, "Engineering Growth"
    end

    should "render 200 for a tenant admin" do
      admin_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: admin_user, role: :admin)
      end

      sign_in admin_user
      get edit_framework_path(@framework.framework_id)

      assert_response :success
    end
  end

  context "GET /frameworks/:id/edit/matrix" do
    should "redirect non-collaborator" do
      sign_in @user
      get edit_matrix_framework_path(@framework.framework_id)

      assert_response :redirect
    end

    should "render turbo frame for a collaborator with suggest rights" do
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person, tenant: @tenant, email: @user.email)
        TenantUser.find_by(user: @user).update!(person: person)
        create(:framework_collaborator, tenant: @tenant,
               framework_id: @framework.framework_id, person_id: person.id,
               role: "collaborator")
      end

      sign_in @user
      get edit_matrix_framework_path(@framework.framework_id)

      assert_response :success
      assert_includes response.body, "turbo-frame"
      assert_not_includes response.body, "<html"
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

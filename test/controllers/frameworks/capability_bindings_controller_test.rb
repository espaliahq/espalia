# frozen_string_literal: true

require "test_helper"

class Frameworks::CapabilityBindingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @role_a = SecureRandom.uuid_v7
      @role_b = SecureRandom.uuid_v7
      @binding_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_a, rfid, "Software Engineer", "E", "ic")
      handler.add_role(@framework_id, @role_b, rfid, "Engineering Manager", "EM", "management")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Critical Thinking")
      handler.create_capability_role_binding(@framework_id, @binding_id, @cap_id, @role_a, weight: 1.0)
      handler.publish_version(@framework_id, "seed")
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "render the binding editor for a capability" do
      get framework_capability_bindings_path(framework_id: @framework_id, capability_id: @cap_id)

      assert_response :success
      assert_select "turbo-frame#binding-editor"
      assert_match(/Software Engineer/, response.body)
      assert_match(/Engineering Manager/, response.body) # the unbound role offered to add
    end

    should "bind a new role and auto-open a draft" do
      post framework_capability_bindings_path(framework_id: @framework_id),
           params: { binding: { capability_id: @cap_id, role_id: @role_b, weight: "2.0" } }

      assert_response :success
      assert framework.draft_in_progress
    end

    should "update a binding's weight (shape-preserving, no draft)" do
      patch framework_capability_binding_path(framework_id: @framework_id, id: @binding_id),
            params: { binding: { weight: "3.5" } }

      assert_response :success
      assert_not framework.draft_in_progress
      binding = ActsAsTenant.with_tenant(@tenant) { FrameworkState::CapabilityRoleBinding.find_by(binding_id: @binding_id) }
      assert_in_delta 3.5, binding.weight.to_f, 0.001
    end

    should "remove a binding and auto-open a draft" do
      delete framework_capability_binding_path(framework_id: @framework_id, id: @binding_id)

      assert_response :success
      assert framework.draft_in_progress
    end

    should "re-render with an error when binding an already-bound role" do
      post framework_capability_bindings_path(framework_id: @framework_id),
           params: { binding: { capability_id: @cap_id, role_id: @role_a } }

      assert_response :unprocessable_content
      assert_match(/already bound/i, response.body)
    end
  end

  context "as a tenant member (no edit rights)" do
    setup { sign_in @member_user }

    should "deny the editor" do
      get framework_capability_bindings_path(framework_id: @framework_id, capability_id: @cap_id)
      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "deny creating a binding" do
      post framework_capability_bindings_path(framework_id: @framework_id),
           params: { binding: { capability_id: @cap_id, role_id: @role_b } }
      assert_redirected_to root_path
    end
  end
end

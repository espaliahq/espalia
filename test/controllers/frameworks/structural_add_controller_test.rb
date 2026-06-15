# frozen_string_literal: true

require "test_helper"

# Covers the add-capability / add-category create actions submitted by the
# shared structural-edit modals.
class Frameworks::StructuralAddControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.publish_version(@framework_id, "seed")
    end
  end

  def framework
    ActsAsTenant.with_tenant(@tenant) { FrameworkState::Framework.find_by!(framework_id: @framework_id) }
  end

  context "POST /frameworks/:framework_id/capabilities" do
    should "add a bound capability for an admin, opening a draft, applied on publish" do
      sign_in @admin_user
      post framework_capabilities_path(framework_id: @framework_id),
           params: { capability: { category_id: @cat_id, name: "Systems Design", role_ids: [ @role_id ] } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Added/, flash[:notice])
      assert framework.draft_in_progress

      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")
        cap = FrameworkState::Capability.find_by(name: "Systems Design")
        assert_not_nil cap
        assert FrameworkState::CapabilityRoleBinding.exists?(capability_id: cap.capability_id, role_id: @role_id)
      end
    end

    should "surface a validation error for an unknown role without opening a draft" do
      sign_in @admin_user
      post framework_capabilities_path(framework_id: @framework_id),
           params: { capability: { category_id: @cat_id, name: "X", role_ids: [ SecureRandom.uuid_v7 ] } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/unknown role/i, flash[:alert])
      assert_not framework.draft_in_progress
    end

    should "deny a plain member" do
      sign_in @member_user
      post framework_capabilities_path(framework_id: @framework_id),
           params: { capability: { category_id: @cat_id, name: "X" } }

      assert_redirected_to root_path
      assert_not framework.draft_in_progress
    end
  end

  context "POST /frameworks/:framework_id/categories" do
    should "add a category live for an admin without opening a draft" do
      sign_in @admin_user
      post framework_categories_path(framework_id: @framework_id),
           params: { category: { name: "Delivery" } }

      assert_redirected_to edit_framework_path(@framework_id)
      assert_match(/Added category/, flash[:notice])
      assert_not framework.draft_in_progress
      assert ActsAsTenant.with_tenant(@tenant) {
        FrameworkState::CapabilityCategory.exists?(framework_id: @framework_id, name: "Delivery")
      }
    end

    should "deny a plain member" do
      sign_in @member_user
      post framework_categories_path(framework_id: @framework_id), params: { category: { name: "Nope" } }
      assert_redirected_to root_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

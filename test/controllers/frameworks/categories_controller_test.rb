# frozen_string_literal: true

require "test_helper"

class Frameworks::CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @owner_person)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "test")
    end
  end

  context "PATCH /frameworks/:framework_id/categories/:id" do
    should "submit a suggest_edit and return the re-rendered name frame" do
      sign_in @user
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "Cognition & Thinking" } }

      assert_response :success
      assert_includes response.body, "category-name-#{@cat_id}"
      assert_includes response.body, "Cognition &amp; Thinking"
    end

    should "keep the edit pending when the suggesting cookie is set" do
      sign_in @user
      cookies[:framework_edit_mode] = "suggesting"
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "Proposed Name" } }

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id,
          target_entity_type: "capability_category",
          target_entity_id: @cat_id
        ).last
        assert_equal "pending", suggestion.status
      end
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: viewer, role: :member)
      end
      sign_in viewer

      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end

    should "404 when the category has been archived" do
      ActsAsTenant.with_tenant(@tenant) do
        FrameworkState::CapabilityCategory.find_by!(category_id: @cat_id).update!(status: "archived")
      end

      sign_in @user
      patch framework_category_path(framework_id: @framework_id, id: @cat_id),
            params: { capability_category: { name: "Cannot edit" } }

      assert_response :not_found
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

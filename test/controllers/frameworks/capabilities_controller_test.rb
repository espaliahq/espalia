# frozen_string_literal: true

require "test_helper"

class Frameworks::CapabilitiesControllerTest < ActionDispatch::IntegrationTest
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
      cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "test")
    end
  end

  context "PATCH /frameworks/:framework_id/capabilities/:id" do
    should "submit a suggest_edit and return the re-rendered name frame" do
      sign_in @user
      patch framework_capability_path(framework_id: @framework_id, id: @cap_id),
            params: { capability: { name: "Sharper Strategic Thinking" } }

      assert_response :success
      assert_includes response.body, "capability-name-#{@cap_id}"
      assert_includes response.body, "Sharper Strategic Thinking"
    end

    should "auto-approve the edit when no cookie is set (editing mode)" do
      sign_in @user
      patch framework_capability_path(framework_id: @framework_id, id: @cap_id),
            params: { capability: { name: "Auto-Applied Name" } }

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id,
          target_entity_type: "capability",
          target_entity_id: @cap_id
        ).last
        assert_equal "approved", suggestion.status,
                     "default cookie state should auto-approve for admins"
      end
    end

    should "keep the edit pending when the suggesting cookie is set" do
      sign_in @user
      cookies[:framework_edit_mode] = "suggesting"
      patch framework_capability_path(framework_id: @framework_id, id: @cap_id),
            params: { capability: { name: "Proposed Only" } }

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id,
          target_entity_type: "capability",
          target_entity_id: @cap_id
        ).last
        assert_equal "pending", suggestion.status,
                     "suggesting cookie should bypass auto-approval"
      end
    end

    should "return unprocessable_content when no editable field is supplied" do
      sign_in @user
      patch framework_capability_path(framework_id: @framework_id, id: @cap_id),
            params: { capability: { name: "" } }

      assert_response :unprocessable_content
    end

    should "return not_found for an unknown capability id" do
      sign_in @user
      patch framework_capability_path(framework_id: @framework_id, id: SecureRandom.uuid_v7),
            params: { capability: { name: "anything" } }

      assert_response :not_found
    end

    should "deny non-contributor viewers" do
      viewer = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: viewer, role: :member)
      end
      sign_in viewer

      patch framework_capability_path(framework_id: @framework_id, id: @cap_id),
            params: { capability: { name: "blocked" } }

      assert_response :redirect
      assert_match(/not authorized/i, flash[:alert])
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

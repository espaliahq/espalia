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

    should "re-render the frame with an inline error and the attempted value on a blank save" do
      sign_in @user
      patch framework_capability_path(framework_id: @framework_id, id: @cap_id),
            params: { capability: { name: "" } }

      # A bodyless 4xx is invisible to Turbo — the user clicks Save and nothing
      # happens. The frame must come back carrying the message.
      assert_response :unprocessable_content
      assert_includes response.body, "Couldn\u2019t save:"
      assert_includes response.body, "data-editor-error"
    end

    should "echo the attempted description back so nothing typed is lost" do
      sign_in @user
      Operations::Frameworks::SuggestEdit.stub :call, ->(*) { raise Operations::Base::ParameterError, "nope" } do
        patch framework_capability_path(framework_id: @framework_id, id: @cap_id),
              params: { capability: { description: "Half-written thought" } }
      end

      assert_response :unprocessable_content
      assert_includes response.body, "Half-written thought"
      assert_includes response.body, "nope"
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

  context "PATCH /frameworks/:framework_id/capabilities/:id (description)" do
    should "edit the description and return the description frame" do
      sign_in @user
      patch framework_capability_path(framework_id: @framework_id, id: @cap_id),
            params: { capability: { description: "Considers long-term impact." } }

      assert_response :success
      assert_includes response.body, "capability-description-#{@cap_id}"
      assert_includes response.body, "Considers long-term impact."
    end

    should "inline-edit a draft-added capability (resolved from the graph, not 404)" do
      draft_cap_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        # Add a capability — shape-changing, so it auto-opens a draft and is
        # deferred from the published read model until publish.
        Frameworks::CommandHandler.new.add_capability(
          @framework_id, draft_cap_id, SecureRandom.uuid_v7,
          FrameworkState::CapabilityCategory.first.category_id, "Draft Cap"
        )
        assert_nil FrameworkState::Capability.find_by(capability_id: draft_cap_id),
                   "precondition: draft-added cap is not in the published read model"
      end

      sign_in @user
      patch framework_capability_path(framework_id: @framework_id, id: draft_cap_id),
            params: { capability: { description: "Drafted inline." } }

      assert_response :success
      assert_includes response.body, "capability-description-#{draft_cap_id}"
      assert_includes response.body, "Drafted inline."
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

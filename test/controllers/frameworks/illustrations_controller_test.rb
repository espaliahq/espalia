# frozen_string_literal: true

require "test_helper"

class Frameworks::IllustrationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @user.email)
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin, person: @owner_person)

      # Build a framework with an illustration via events
      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      @rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      @eid = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7

      # create_framework opens a bootstrap v1 draft automatically.
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @rid, 1, "E1", "E1")
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, @rid)
      handler.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, cap_id, 1, "Asks questions")
      handler.add_role_illustration(
        @framework_id, @ill_id, SecureRandom.uuid_v7, @eid, @rid, 1, "Seeks guidance from tech lead"
      )
      # Add owner collaborator so the aggregate has at least one collaborator
      # (otherwise can_approve? returns true for everyone).
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      # Publish v1 so shape-changing read models (capability, expectation, binding)
      # are materialized — required for the controller tests to find the parent.
      handler.publish_version(@framework_id, "test")
    end
  end

  context "POST /frameworks/:framework_id/illustrations" do
    should "create illustration and return Turbo Stream with append + replace actions" do
      sign_in @user
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: @eid, role_id: @rid, description: "New example" } }

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html", response.media_type
      assert_includes response.body, "New example"
      assert_includes response.body, "turbo-stream"
      assert_includes response.body, "illustrations-#{@eid}-#{@rid}"
      assert_includes response.body, "new-illustration-#{@eid}-#{@rid}"
    end

    should "persist the new illustration in the read model (auto-approved)" do
      sign_in @user
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: @eid, role_id: @rid, description: "Persisted example" } }

      ActsAsTenant.with_tenant(@tenant) do
        ill = FrameworkState::RoleIllustration.find_by(
          expectation_id: @eid, role_id: @rid, description: "Persisted example"
        )
        assert_not_nil ill
        assert_equal 2, ill.ordinal
      end
    end

    should "create EntityCreationSuggested + SuggestionApproved + RoleIllustrationAdded events" do
      sign_in @user
      stream = ActsAsTenant.with_tenant(@tenant) { EventStreamNaming.framework_stream(@framework_id) }
      event_store = Rails.configuration.event_store
      events_before = event_store.read.stream(stream).to_a.size

      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: @eid, role_id: @rid, description: "Event trail" } }

      events_after = event_store.read.stream(stream).to_a
      new_events = events_after[events_before..]
      assert_equal 3, new_events.size,
                   "Expected 3 new events (EntityCreationSuggested + SuggestionApproved + RoleIllustrationAdded)"
      assert_instance_of Frameworks::Events::EntityCreationSuggested, new_events[0]
      assert_instance_of Frameworks::Events::SuggestionApproved, new_events[1]
      assert_instance_of Frameworks::Events::RoleIllustrationAdded, new_events[2]
    end

    should "create pending suggestion when collaborator lacks approval rights" do
      collab_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person, tenant: @tenant, email: collab_user.email)
        create(:tenant_user, tenant: @tenant, user: collab_user, role: :member, person: person)
        # Add collaborator via command handler so the aggregate tracks them
        Frameworks::CommandHandler.new.add_collaborator(
          @framework_id, person.id.to_s, "collaborator", added_by: @owner_person.id.to_s
        )
      end

      sign_in collab_user
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: @eid, role_id: @rid, description: "Pending example" } }

      assert_response :success

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(
          framework_id: @framework_id, kind: "create",
          target_entity_type: "role_illustration", status: "pending"
        )
        assert_not_nil suggestion
        assert_equal "Pending example", suggestion.proposed_attributes["description"]

        ill = FrameworkState::RoleIllustration.find_by(description: "Pending example")
        assert_nil ill, "Illustration should not exist until approved"
      end
    end

    should "auto-approve when collaborator has edit rights" do
      editor_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person, tenant: @tenant, email: editor_user.email)
        create(:tenant_user, tenant: @tenant, user: editor_user, role: :member, person: person)
        # Add role_lead via command handler so the aggregate recognises approval authority
        Frameworks::CommandHandler.new.add_collaborator(
          @framework_id, person.id.to_s, "role_lead", added_by: @owner_person.id.to_s
        )
      end

      sign_in editor_user
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: @eid, role_id: @rid, description: "Auto-approved" } }

      assert_response :success

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(
          framework_id: @framework_id, kind: "create",
          target_entity_type: "role_illustration"
        )
        assert_equal "approved", suggestion.status

        ill = FrameworkState::RoleIllustration.find_by(description: "Auto-approved")
        assert_not_nil ill, "Illustration should exist after auto-approval"
      end
    end

    should "deny viewer collaborators" do
      viewer_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        person = create(:person, tenant: @tenant, email: viewer_user.email)
        create(:tenant_user, tenant: @tenant, user: viewer_user, role: :member, person: person)
        # Viewer collaborator added via command handler
        Frameworks::CommandHandler.new.add_collaborator(
          @framework_id, person.id.to_s, "viewer", added_by: @owner_person.id.to_s
        )
      end

      sign_in viewer_user
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: @eid, role_id: @rid, description: "Viewer attempt" } }

      assert_response :redirect
      follow_redirect!
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "return 404 for an unknown expectation" do
      sign_in @user
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: SecureRandom.uuid_v7, role_id: @rid, description: "X" } }

      # The Operation pre-validates the parent against the explorer graph and
      # raises RecordNotFound — a bad id is a 404, not a 422.
      assert_response :not_found
    end

    should "redirect unauthenticated users to sign in" do
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: @eid, role_id: @rid, description: "X" } }

      assert_redirected_to new_user_session_path
    end

    should "deny non-admin members without collaborator role" do
      member_user = create(:user, password: "password123")
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: member_user, role: :member)
      end

      sign_in member_user
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: @eid, role_id: @rid, description: "Unauthorized" } }

      assert_response :redirect
      follow_redirect!
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "PATCH /frameworks/:framework_id/illustrations/:id" do
    should "update illustration description and return Turbo Frame" do
      sign_in @user
      patch framework_illustration_path(framework_id: @framework_id, id: @ill_id),
            params: { illustration: { description: "Asks clarifying questions proactively" } }

      assert_response :success
      assert_includes response.body, "Asks clarifying questions proactively"
      assert_includes response.body, "turbo-frame"
      assert_includes response.body, "illustration-#{@ill_id}"
    end

    should "keep the edit pending when the suggesting cookie is set" do
      sign_in @user
      cookies[:framework_edit_mode] = "suggesting"
      patch framework_illustration_path(framework_id: @framework_id, id: @ill_id),
            params: { illustration: { description: "Proposed only" } }

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.where(
          framework_id: @framework_id,
          target_entity_type: "role_illustration",
          target_entity_id: @ill_id
        ).last
        assert_equal "pending", suggestion.status
      end
    end

    should "include the pencil affordance in the response so re-editing stays possible" do
      sign_in @user
      patch framework_illustration_path(framework_id: @framework_id, id: @ill_id),
            params: { illustration: { description: "First edit" } }

      assert_response :success
      # Pencil button has data-action="field-editor#open" — if mode: is not
      # passed as :edit the button (and the data-editor-* host the shared editor
      # reads) are dropped and subsequent edits become impossible.
      assert_includes response.body, "field-editor#open",
                      "response must retain the edit affordance for the next click"
      assert_includes response.body, "data-editor-action",
                      "response must retain the shared editor's host data"
    end

    should "create 3 events (EditSuggested + SuggestionApproved + RoleIllustrationUpdated)" do
      sign_in @user
      stream = ActsAsTenant.with_tenant(@tenant) { EventStreamNaming.framework_stream(@framework_id) }
      event_store = Rails.configuration.event_store
      events_before = event_store.read.stream(stream).to_a.size

      patch framework_illustration_path(framework_id: @framework_id, id: @ill_id),
            params: { illustration: { description: "New description" } }

      events_after = event_store.read.stream(stream).to_a.size
      assert_equal events_before + 3, events_after,
                   "Expected 3 new events (EditSuggested + SuggestionApproved + RoleIllustrationUpdated)"
    end

    should "persist the updated description in the read model" do
      sign_in @user
      patch framework_illustration_path(framework_id: @framework_id, id: @ill_id),
            params: { illustration: { description: "Persistent update" } }

      ActsAsTenant.with_tenant(@tenant) do
        ill = FrameworkState::RoleIllustration.find_by(illustration_id: @ill_id)
        assert_equal "Persistent update", ill.description
      end
    end

    should "return 404 for unknown illustration" do
      sign_in @user
      patch framework_illustration_path(framework_id: @framework_id, id: SecureRandom.uuid_v7),
            params: { illustration: { description: "X" } }

      assert_response :not_found
    end

    should "redirect unauthenticated users to sign in" do
      patch framework_illustration_path(framework_id: @framework_id, id: @ill_id),
            params: { illustration: { description: "X" } }

      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

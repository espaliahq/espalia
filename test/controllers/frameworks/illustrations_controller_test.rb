# frozen_string_literal: true

require "test_helper"

class Frameworks::IllustrationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @user, role: :admin)

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

    should "persist the new illustration in the read model" do
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

    should "return 422 for unknown expectation passed to aggregate" do
      sign_in @user
      post framework_illustrations_path(framework_id: @framework_id),
           params: { illustration: { expectation_id: SecureRandom.uuid_v7, role_id: @rid, description: "X" } }

      assert_response :unprocessable_content
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

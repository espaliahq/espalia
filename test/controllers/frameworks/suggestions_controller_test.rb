# frozen_string_literal: true

require "test_helper"

class Frameworks::SuggestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")
    @author_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      create(:tenant_user, tenant: @tenant, user: @author_user, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      rfid = SecureRandom.uuid_v7
      rid = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      @eid = SecureRandom.uuid_v7
      @ill_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Test Framework")
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, rid, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, rid, 1, "E1", "E1")
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, cap_id, rid)
      handler.set_behavioural_expectation(@framework_id, @eid, SecureRandom.uuid_v7, cap_id,
                                          1, "Asks questions")
      handler.add_role_illustration(
        @framework_id, @ill_id, SecureRandom.uuid_v7, @eid, rid, 1, "Seeks guidance"
      )
      handler.publish_version(@framework_id, "test")

      # Seed two pending suggestions, authored by @author_user (not auto-approved
      # because we use mode: :suggesting).
      @illustration_suggestion_id = SecureRandom.uuid_v7
      handler.suggest_edit(
        @framework_id, @illustration_suggestion_id,
        "role_illustration", @ill_id, "description",
        "Proactively seeks clarification", @author_user.id.to_s,
        rationale: "Sharper wording",
        mode: :suggesting
      )

      @expectation_suggestion_id = SecureRandom.uuid_v7
      handler.suggest_edit(
        @framework_id, @expectation_suggestion_id,
        "behavioural_expectation", @eid, "description",
        "Asks open-ended questions to surface assumptions", @author_user.id.to_s,
        mode: :suggesting
      )
    end
  end

  context "GET /frameworks/:framework_id/suggestions" do
    should "render the index for tenant members" do
      sign_in @member_user
      get framework_suggestions_path(framework_id: @framework_id)

      assert_response :success
      assert_includes response.body, "Suggested edits"
      assert_includes response.body, "Proactively seeks clarification"
      assert_includes response.body, "Asks open-ended questions"
    end

    should "render the panel layout when ?layout=panel" do
      sign_in @member_user
      get framework_suggestions_path(framework_id: @framework_id, layout: "panel")

      assert_response :success
      assert_includes response.body, "suggestion-panel"
      assert_includes response.body, "pending"
    end

    should "filter by status" do
      sign_in @member_user
      get framework_suggestions_path(framework_id: @framework_id, status: "approved")

      assert_response :success
      assert_includes response.body, "No suggestions match these filters"
    end

    should "redirect unauthenticated users to sign in" do
      get framework_suggestions_path(framework_id: @framework_id)
      assert_redirected_to new_user_session_path
    end
  end

  context "GET /frameworks/:framework_id/suggestions/:id" do
    should "render the detail page" do
      sign_in @member_user
      get framework_suggestion_path(framework_id: @framework_id, id: @illustration_suggestion_id)

      assert_response :success
      assert_includes response.body, "Proactively seeks clarification"
      assert_includes response.body, "Sharper wording"
    end

    should "redirect to index when suggestion is unknown" do
      sign_in @member_user
      get framework_suggestion_path(framework_id: @framework_id, id: SecureRandom.uuid_v7)

      assert_redirected_to framework_suggestions_path(framework_id: @framework_id)
    end
  end

  context "POST /frameworks/:framework_id/suggestions/:id/approve" do
    should "approve a tier 1 illustration suggestion as admin and update the read model" do
      sign_in @admin_user
      post approve_framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      )

      assert_redirected_to framework_suggestions_path(framework_id: @framework_id)

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(
          suggestion_id: @illustration_suggestion_id
        )
        assert_equal "approved", suggestion.status
        assert_equal "Proactively seeks clarification",
                     FrameworkState::RoleIllustration.find_by(illustration_id: @ill_id).description
      end
    end

    should "approve a tier 3 expectation suggestion as admin and update the read model" do
      sign_in @admin_user
      post approve_framework_suggestion_path(
        framework_id: @framework_id, id: @expectation_suggestion_id
      )

      assert_redirected_to framework_suggestions_path(framework_id: @framework_id)

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(
          suggestion_id: @expectation_suggestion_id
        )
        assert_equal "approved", suggestion.status
        assert_equal "Asks open-ended questions to surface assumptions",
                     FrameworkState::BehaviouralExpectation.find_by(expectation_id: @eid).description
      end
    end

    should "deny a non-admin tenant member" do
      sign_in @member_user
      post approve_framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      )

      assert_response :redirect
      follow_redirect!
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "POST /frameworks/:framework_id/suggestions/:id/reject" do
    should "reject a pending suggestion as admin" do
      sign_in @admin_user
      post reject_framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      )

      assert_redirected_to framework_suggestions_path(framework_id: @framework_id)

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(
          suggestion_id: @illustration_suggestion_id
        )
        assert_equal "rejected", suggestion.status
      end
    end

    should "deny non-admin members" do
      sign_in @member_user
      post reject_framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      )

      assert_response :redirect
      follow_redirect!
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "PATCH /frameworks/:framework_id/suggestions/:id/amend" do
    should "amend the author's own pending suggestion" do
      sign_in @author_user
      patch amend_framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      ), params: { suggestion: { suggested_value: "Revised wording", rationale: "Even sharper" } }

      assert_redirected_to framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      )

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(
          suggestion_id: @illustration_suggestion_id
        )
        assert_equal "Revised wording", suggestion.suggested_value
      end
    end

    should "deny non-author members" do
      sign_in @member_user
      patch amend_framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      ), params: { suggestion: { suggested_value: "Hijacked" } }

      assert_response :redirect
      follow_redirect!
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "DELETE /frameworks/:framework_id/suggestions/:id" do
    should "withdraw the author's own pending suggestion" do
      sign_in @author_user
      delete framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      )

      assert_redirected_to framework_suggestions_path(framework_id: @framework_id)

      ActsAsTenant.with_tenant(@tenant) do
        suggestion = FrameworkState::SuggestedEdit.find_by(
          suggestion_id: @illustration_suggestion_id
        )
        assert_equal "withdrawn", suggestion.status
      end
    end

    should "deny non-author members" do
      sign_in @member_user
      delete framework_suggestion_path(
        framework_id: @framework_id, id: @illustration_suggestion_id
      )

      assert_response :redirect
      follow_redirect!
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

# frozen_string_literal: true

require "test_helper"

class Assessments::CommentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @assessee_user = create(:user, password: "password123")
    @manager_user = create(:user, password: "password123")
    @peer_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = create(:person, tenant: @tenant, email: @manager_user.email, name: "Mgr")
      create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

      @assessee = create(:person, tenant: @tenant, email: @assessee_user.email, name: "Dev",
        manager: @manager)
      create(:tenant_user, tenant: @tenant, user: @assessee_user, person: @assessee)

      @peer = create(:person, tenant: @tenant, email: @peer_user.email, name: "Peer")
      create(:tenant_user, tenant: @tenant, user: @peer_user, person: @peer)

      framework_id = SecureRandom.uuid_v7
      @framework = create(:framework_state, framework_id: framework_id, name: "Engineering Growth")
      rf = create(:framework_role_family, framework_id: framework_id, name: "Engineering")
      @role = create(:framework_role,
        role_family_id: rf.role_family_id, name: "Software Engineer", code: "E", track: "ic")
      @level = create(:framework_level, role_id: @role.role_id, ordinal: 2, title: "Mid", code: "E2")
      @cat = create(:framework_capability_category, framework_id: framework_id, name: "Thinking", ordinal: 1)
      @cap = create(:framework_capability, category_id: @cat.category_id, name: "Critical Thinking")
      create(:framework_capability_role_binding,
        capability_id: @cap.capability_id, role_id: @role.role_id, weight: 1.0)
      create(:framework_behavioural_expectation,
        capability_id: @cap.capability_id, level_ordinal: 2, description: "Synthesises")

      PersonDevelopment::CommandHandler.new.assign_to_framework(
        @assessee.id, framework_id, @role.role_id, @level.level_id
      )

      @assignment = PersonFrameworkAssignment.for_person(@assessee.id).first
    end
  end

  context "POST /assessments/:assessment_id/comments" do
    should "let the assessee post a comment on their own assessment" do
      sign_in @assessee_user
      post assessment_comments_path(@assignment), params: {
        comment: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          body: "Working on this with my mentor."
        }
      }
      follow_redirect!
      assert_response :success

      ActsAsTenant.with_tenant(@tenant) do
        c = PersonDevelopmentComment.last
        assert_not_nil c
        assert_equal "Working on this with my mentor.", c.body
        assert_equal @assessee.id, c.author_id
        assert_equal "active", c.status
      end
    end

    should "let the manager post a comment on their report's assessment" do
      sign_in @manager_user
      post assessment_comments_path(@assignment), params: {
        comment: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          body: "I see this in the customer call you ran last week."
        }
      }
      assert_response :redirect

      ActsAsTenant.with_tenant(@tenant) do
        c = PersonDevelopmentComment.last
        assert_equal @manager.id, c.author_id
      end
    end

    should "redirect with capability and category so the matrix lands on the right cell" do
      sign_in @assessee_user
      post assessment_comments_path(@assignment), params: {
        comment: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          body: "x"
        }
      }
      assert_response :redirect
      assert_match "capability=#{@cap.stable_id}", response.location
      assert_match "category=#{@cat.category_id}", response.location
      assert_match "level_ordinal=2", response.location
    end

    should "reject blank body" do
      sign_in @assessee_user
      post assessment_comments_path(@assignment), params: {
        comment: { capability_stable_id: @cap.stable_id, level_ordinal: 2, body: "   " }
      }
      assert_response :redirect
      ActsAsTenant.with_tenant(@tenant) { assert_equal 0, PersonDevelopmentComment.count }
    end

    should "reject invalid level_ordinal" do
      sign_in @assessee_user
      post assessment_comments_path(@assignment), params: {
        comment: { capability_stable_id: @cap.stable_id, level_ordinal: 99, body: "x" }
      }
      assert_response :unprocessable_content
    end
  end

  context "PATCH /assessments/:assessment_id/comments/:id" do
    setup do
      sign_in @assessee_user
      post assessment_comments_path(@assignment), params: {
        comment: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          body: "Original"
        }
      }
      ActsAsTenant.with_tenant(@tenant) { @comment = PersonDevelopmentComment.last }
    end

    should "let the author edit their own comment" do
      patch assessment_comment_path(@assignment, @comment), params: {
        comment: { body: "Updated" }
      }
      assert_response :redirect
      ActsAsTenant.with_tenant(@tenant) do
        @comment.reload
        assert_equal "Updated", @comment.body
        assert_not_nil @comment.edited_at
      end
    end

    should "deny edit by a different user" do
      delete destroy_user_session_path
      sign_in @manager_user
      patch assessment_comment_path(@assignment, @comment), params: {
        comment: { body: "Hijack" }
      }
      # PersonDevelopmentCommentPolicy#update? denies non-authors. Pundit
      # raises NotAuthorizedError which the controller rescues to a
      # redirect with an alert.
      assert_response :redirect
      ActsAsTenant.with_tenant(@tenant) do
        @comment.reload
        assert_equal "Original", @comment.body
      end
    end
  end

  context "DELETE /assessments/:assessment_id/comments/:id" do
    setup do
      sign_in @assessee_user
      post assessment_comments_path(@assignment), params: {
        comment: {
          capability_stable_id: @cap.stable_id,
          level_ordinal: 2,
          body: "Original"
        }
      }
      ActsAsTenant.with_tenant(@tenant) { @comment = PersonDevelopmentComment.last }
    end

    should "let the author delete their own comment (soft-delete)" do
      delete assessment_comment_path(@assignment, @comment)
      assert_response :redirect
      ActsAsTenant.with_tenant(@tenant) do
        @comment.reload
        assert_equal "deleted", @comment.status
        assert_not_nil @comment.deleted_at
      end
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

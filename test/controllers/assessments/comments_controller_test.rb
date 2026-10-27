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

    should "let an active rating delegate comment (not just the manager chain)" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:manager_assessment_delegation, tenant: @tenant, person_id: @assessee.id,
          framework_id: @framework.framework_id, delegate_person_id: @peer.id,
          granted_by_id: @manager.id)
      end
      sign_in @peer_user
      post assessment_comments_path(@assignment), params: {
        comment: { capability_stable_id: @cap.stable_id, level_ordinal: 2, body: "Saw this on the Payments team." }
      }
      assert_response :redirect

      ActsAsTenant.with_tenant(@tenant) do
        assert_equal @peer.id, PersonDevelopmentComment.last.author_id
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

    should "respond 404 (not 500) when the assignment id does not exist" do
      sign_in @assessee_user
      post assessment_comments_path(SecureRandom.uuid_v7), params: {
        comment: { capability_stable_id: @cap.stable_id, level_ordinal: 2, body: "x" }
      }
      assert_response :not_found
    end

    should "let a reply target another reply (multi-level threading)" do
      sign_in @assessee_user
      cell = { capability_stable_id: @cap.stable_id, level_ordinal: 2 }

      post assessment_comments_path(@assignment), params: { comment: cell.merge(body: "Top") }
      assert_response :redirect
      top = ActsAsTenant.with_tenant(@tenant) { PersonDevelopmentComment.last }

      post assessment_comments_path(@assignment),
        params: { comment: cell.merge(body: "Reply", parent_id: top.id) }
      assert_response :redirect
      reply = ActsAsTenant.with_tenant(@tenant) { PersonDevelopmentComment.last }
      assert_equal top.id, reply.parent_id

      post assessment_comments_path(@assignment),
        params: { comment: cell.merge(body: "Reply to a reply", parent_id: reply.id) }
      assert_response :redirect

      ActsAsTenant.with_tenant(@tenant) do
        nested = PersonDevelopmentComment.last
        assert_equal "Reply to a reply", nested.body
        assert_equal reply.id, nested.parent_id
        assert_equal "active", nested.status
      end
    end
  end

  context "rendered thread on the assessment page" do
    setup do
      sign_in @assessee_user
      @cell = { capability_stable_id: @cap.stable_id, level_ordinal: 2 }
      post assessment_comments_path(@assignment), params: { comment: @cell.merge(body: "Anchor point") }
      @anchor = ActsAsTenant.with_tenant(@tenant) { PersonDevelopmentComment.last }
    end

    should "omit the reply chip when the parent is the comment directly above" do
      post assessment_comments_path(@assignment),
        params: { comment: @cell.merge(body: "Right below", parent_id: @anchor.id) }

      get assessment_path(@assignment)
      assert_response :success
      assert_no_match(/replying to/, response.body)
    end

    should "show the reply chip when the parent is not the comment directly above" do
      # Two replies to the same anchor: the first sits directly under the
      # anchor (no chip); the second is separated from the anchor by the
      # first reply, so it surfaces a "↳ replying to Dev" chip.
      post assessment_comments_path(@assignment),
        params: { comment: @cell.merge(body: "First reply", parent_id: @anchor.id) }
      post assessment_comments_path(@assignment),
        params: { comment: @cell.merge(body: "Second reply", parent_id: @anchor.id) }

      get assessment_path(@assignment)
      assert_response :success
      assert_match(/↳ replying to #{@assessee.name}/, response.body)
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

  TURBO_STREAM_ACCEPT = { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }.freeze

  context "Turbo Stream responses" do
    setup do
      sign_in @assessee_user
      @cell = { capability_stable_id: @cap.stable_id, level_ordinal: 2 }
    end

    should "replace just the thread and the chip when a comment is posted, and name the cell" do
      post_stream assessment_comments_path(@assignment), comment: @cell.merge(body: "Working on it.")

      assert_thread_stream
      assert_includes response.body, "Working on it."
      assert_includes response.body, %(target="assessment-live-status")
      assert_includes response.body, "Comment posted — Critical Thinking, E2"
      assert_not_includes response.body, "capability-card-", "the card itself stays, with whatever is open in it"
      assert_includes stream_html("cell-#{@cap.stable_id}-2"), %(data-glyph="comment")
      ActsAsTenant.with_tenant(@tenant) { assert_equal "Working on it.", PersonDevelopmentComment.last.body }
    end

    should "render the thread and the chip at the level the comment was posted on" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_level, role_id: @role.role_id, ordinal: 3, title: "Senior", code: "E3")
        create(:framework_behavioural_expectation,
          capability_id: @cap.capability_id, level_ordinal: 3, description: "Shapes the team's thinking")
      end

      post_stream assessment_comments_path(@assignment), comment: @cell.merge(level_ordinal: 3, body: "Stretch")

      assert_thread_stream(level_ordinal: 3)
      assert_includes response.body, "Comment posted — Critical Thinking, E3"
      assert_includes stream_html("cell-#{@cap.stable_id}-3"), %(aria-pressed="true"), "the chip stays selected"
    end

    should "replace the thread when a reply is posted" do
      top = post_comment_as_html("Top")
      post_stream assessment_comments_path(@assignment), comment: @cell.merge(body: "A reply", parent_id: top.id)

      assert_thread_stream
      assert_includes response.body, "A reply"
      ActsAsTenant.with_tenant(@tenant) { assert_equal top.id, PersonDevelopmentComment.last.parent_id }
    end

    should "replace the thread when a comment is edited" do
      comment = post_comment_as_html("Original")
      patch assessment_comment_path(@assignment, comment), params: { comment: { body: "Revised" } },
        headers: TURBO_STREAM_ACCEPT

      assert_thread_stream
      assert_includes response.body, "Revised"
      assert_includes response.body, "Comment updated — Critical Thinking, E2"
    end

    should "replace the thread and clear the chip's glyph when the last comment is deleted" do
      comment = post_comment_as_html("Short-lived")
      delete assessment_comment_path(@assignment, comment), headers: TURBO_STREAM_ACCEPT

      assert_thread_stream
      assert_not_includes response.body, "Short-lived"
      assert_not_includes stream_html("cell-#{@cap.stable_id}-2"), %(data-glyph="comment")
      assert_includes response.body, "Comment deleted — Critical Thinking, E2"
    end

    should "carry the page's lens through to the thread and the redirect" do
      ActsAsTenant.with_tenant(@tenant) do
        create(:framework_level, role_id: @role.role_id, ordinal: 3, title: "Senior", code: "E3")
        create(:framework_behavioural_expectation,
          capability_id: @cap.capability_id, level_ordinal: 3, description: "Shapes the team's thinking")
      end

      post_stream assessment_comments_path(@assignment, as_level: 3), comment: @cell.merge(body: "Through a lens")
      assert_thread_stream
      assert_includes response.body, %(action="/assessments/#{@assignment.id}/comments?as_level=3")

      post assessment_comments_path(@assignment, as_level: 3), params: { comment: @cell.merge(body: "Without Turbo") }
      assert_match "as_level=3", response.location
    end

    should "save the comment through a stale lens and fall back to the home view" do
      post_stream assessment_comments_path(@assignment, as_role: SecureRandom.uuid_v7, as_level: 2),
        comment: @cell.merge(body: "Not lost")

      assert_no_stream
      assert_response :see_other
      assert_match "capability=#{@cap.stable_id}", response.location
      assert_no_match "as_role", response.location
      ActsAsTenant.with_tenant(@tenant) { assert_equal "Not lost", PersonDevelopmentComment.last.body }
    end

    should "save an edit and a delete through a stale lens" do
      comment = post_comment_as_html("Original")
      stale = { as_role: SecureRandom.uuid_v7, as_level: 2 }

      patch assessment_comment_path(@assignment, comment, stale), params: { comment: { body: "Revised" } },
        headers: TURBO_STREAM_ACCEPT
      assert_no_stream
      assert_no_match "as_role", response.location
      ActsAsTenant.with_tenant(@tenant) { assert_equal "Revised", comment.reload.body }

      delete assessment_comment_path(@assignment, comment, stale), headers: TURBO_STREAM_ACCEPT
      assert_no_stream
      ActsAsTenant.with_tenant(@tenant) { assert_not_nil comment.reload.deleted_at }
    end

    should "redirect a request that accepts anything" do
      post assessment_comments_path(@assignment), params: { comment: @cell.merge(body: "Any format") },
        headers: { "Accept" => "*/*" }

      assert_response :see_other
      assert_match "capability=#{@cap.stable_id}", response.location
    end

    should "tell the new thread to focus the viewer's own comment, or itself after a delete" do
      post_stream assessment_comments_path(@assignment), comment: @cell.merge(body: "Mine")
      comment = ActsAsTenant.with_tenant(@tenant) { PersonDevelopmentComment.last }
      assert_includes thread_html, %(data-comments-thread-focus-value="comment-#{comment.id}")

      patch assessment_comment_path(@assignment, comment), params: { comment: { body: "Mine, revised" } },
        headers: TURBO_STREAM_ACCEPT
      assert_includes thread_html, %(data-comments-thread-focus-value="comment-#{comment.id}")

      delete assessment_comment_path(@assignment, comment), headers: TURBO_STREAM_ACCEPT
      assert_includes thread_html, %(data-comments-thread-focus-value="thread")
    end

    should "keep the redirect for a request that isn't Turbo's" do
      post assessment_comments_path(@assignment), params: { comment: @cell.merge(body: "Plain form") }

      assert_response :see_other
      assert_match "capability=#{@cap.stable_id}", response.location
      assert_equal "Comment posted.", flash[:notice]
    end

    should "still deny another viewer's edit, with no stream" do
      comment = post_comment_as_html("Mine")
      sign_out_and_in @manager_user
      patch assessment_comment_path(@assignment, comment), params: { comment: { body: "Hijack" } },
        headers: TURBO_STREAM_ACCEPT

      assert_no_stream
      ActsAsTenant.with_tenant(@tenant) { assert_equal "Mine", comment.reload.body }
    end

    context "for an author who can no longer see the assessment" do
      setup do
        @other_manager = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant, name: "New Mgr") }
      end

      should "send a former manager's edit and delete no stream" do
        sign_out_and_in @manager_user
        comment = post_comment_as_html("Before the reorg")
        ActsAsTenant.with_tenant(@tenant) { @assessee.update!(manager: @other_manager) }

        patch assessment_comment_path(@assignment, comment), params: { comment: { body: "After" } },
          headers: TURBO_STREAM_ACCEPT
        assert_no_stream

        delete assessment_comment_path(@assignment, comment), headers: TURBO_STREAM_ACCEPT
        assert_no_stream
      end

      should "send a revoked delegate's edit and delete no stream" do
        delegation = ActsAsTenant.with_tenant(@tenant) do
          create(:manager_assessment_delegation, tenant: @tenant, person_id: @assessee.id,
            framework_id: @framework.framework_id, delegate_person_id: @peer.id, granted_by_id: @manager.id)
        end
        sign_out_and_in @peer_user
        comment = post_comment_as_html("While delegated")
        ActsAsTenant.with_tenant(@tenant) { delegation.update!(status: "revoked") }

        patch assessment_comment_path(@assignment, comment), params: { comment: { body: "After" } },
          headers: TURBO_STREAM_ACCEPT
        assert_no_stream

        delete assessment_comment_path(@assignment, comment), headers: TURBO_STREAM_ACCEPT
        assert_no_stream
      end
    end
  end

  private

  def post_stream(path, comment:)
    post path, params: { comment: comment }, headers: TURBO_STREAM_ACCEPT
  end

  def post_comment_as_html(body)
    post assessment_comments_path(@assignment), params: { comment: @cell.merge(body: body) }
    ActsAsTenant.with_tenant(@tenant) { PersonDevelopmentComment.last }
  end

  def assert_thread_stream(level_ordinal: 2)
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body,
      %(action="replace" target="comments-thread-#{@cap.stable_id}-#{level_ordinal}")
    assert_includes response.body, %(action="replace" target="cell-#{@cap.stable_id}-#{level_ordinal}")
  end

  def assert_no_stream
    assert_response :redirect
    assert_not_includes response.body, "<turbo-stream"
    assert_not_includes response.body, "comments-thread-"
  end

  # The markup one replace stream carries.
  def stream_html(target)
    Nokogiri::HTML5.fragment(response.body).at_css(%(turbo-stream[target="#{target}"] template)).inner_html
  end

  def thread_html
    stream_html("comments-thread-#{@cap.stable_id}-2")
  end

  def sign_out_and_in(user)
    delete destroy_user_session_path
    sign_in user
  end

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

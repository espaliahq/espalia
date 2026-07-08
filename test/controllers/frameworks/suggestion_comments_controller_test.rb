# frozen_string_literal: true

require "test_helper"

# The suggestion discussion-thread web endpoints: post / reply / edit /
# delete from the pane card and detail surfaces, redirect targets per
# return_to, and denied paths (non-collaborator member of the tenant,
# non-author edit).
class Frameworks::SuggestionCommentsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @collab_user = create(:user, password: "password123")
    @other_collab_user = create(:user, password: "password123")
    @outsider_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @collab_person = create(:person, tenant: @tenant, email: @collab_user.email)
      @other_collab_person = create(:person, tenant: @tenant, email: @other_collab_user.email)
      create(:tenant_user, tenant: @tenant, user: @collab_user, role: :member, person: @collab_person)
      create(:tenant_user, tenant: @tenant, user: @other_collab_user, role: :member, person: @other_collab_person)
      create(:tenant_user, tenant: @tenant, user: @outsider_user, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
      handler.publish_version(@framework_id, "test")
      handler.add_collaborator(@framework_id, @collab_person.id.to_s, "collaborator",
                               added_by: @collab_person.id.to_s)
      handler.add_collaborator(@framework_id, @other_collab_person.id.to_s, "collaborator",
                               added_by: @collab_person.id.to_s)

      @suggestion_id = SecureRandom.uuid_v7
      handler.suggest_edit(@framework_id, @suggestion_id, "capability", @cap_id,
                           "description", "Proposed", @collab_person.id.to_s, mode: :suggesting)
    end
  end

  def post_comment(body:, parent_id: nil, return_to: nil)
    post framework_suggestion_comments_path(@framework_id, @suggestion_id),
         params: { comment: { body: body, parent_id: parent_id }, return_to: return_to }.compact
  end

  context "as a collaborator" do
    setup { sign_in @collab_user }

    should "post a comment and redirect to the pane card" do
      post_comment(body: "Worth discussing")

      assert_redirected_to framework_activity_path(
        @framework_id, focus: "suggestion", suggestion_id: @suggestion_id, layout: "panel"
      )
      comment = FrameworkState::SuggestionComment.sole
      assert_equal "Worth discussing", comment.body
      assert_equal @collab_person.id, comment.author_id
    end

    should "redirect to the detail page when return_to=detail" do
      post_comment(body: "From the detail page", return_to: "detail")

      assert_redirected_to framework_suggestion_path(@framework_id, @suggestion_id)
    end

    should "post a reply threaded under its parent" do
      post_comment(body: "Top")
      parent = FrameworkState::SuggestionComment.sole

      post_comment(body: "Reply", parent_id: parent.id)

      reply = FrameworkState::SuggestionComment.find_by(parent_id: parent.id)
      assert_equal "Reply", reply.body
    end

    should "surface a client mistake as a flash alert" do
      post_comment(body: "Reply", parent_id: SecureRandom.uuid_v7)

      assert_redirected_to framework_activity_path(
        @framework_id, focus: "suggestion", suggestion_id: @suggestion_id, layout: "panel"
      )
      assert_match(/parent comment not found/, flash[:alert])
    end

    should "edit their own comment" do
      post_comment(body: "Original")
      comment = FrameworkState::SuggestionComment.sole

      patch framework_suggestion_comment_path(@framework_id, @suggestion_id, comment.id),
            params: { comment: { body: "Revised" } }

      assert_equal "Revised", comment.reload.body
    end

    should "delete their own comment (soft)" do
      post_comment(body: "Original")
      comment = FrameworkState::SuggestionComment.sole

      delete framework_suggestion_comment_path(@framework_id, @suggestion_id, comment.id)

      assert_equal "deleted", comment.reload.status
    end

    should "be denied editing someone else's comment" do
      post_comment(body: "Original")
      comment = FrameworkState::SuggestionComment.sole
      sign_in @other_collab_user

      patch framework_suggestion_comment_path(@framework_id, @suggestion_id, comment.id),
            params: { comment: { body: "Hijack" } }

      assert_redirected_to root_path
      assert_equal "Original", comment.reload.body
    end
  end

  context "as a tenant member without a collaborator role" do
    setup { sign_in @outsider_user }

    should "be denied posting" do
      post_comment(body: "Hi")

      assert_redirected_to root_path
      assert_equal 0, ActsAsTenant.with_tenant(@tenant) { FrameworkState::SuggestionComment.count }
    end
  end
end

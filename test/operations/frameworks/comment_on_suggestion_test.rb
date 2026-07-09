# frozen_string_literal: true

require "test_helper"

# CommentOnSuggestion posts to a suggestion's discussion thread: top-level
# comments and replies (any non-deleted comment on the same suggestion),
# open threads on resolved suggestions, and client-mistake classification
# (blank body, unknown suggestion, cross-suggestion or deleted parents).
class Operations::Frameworks::CommentOnSuggestionTest < ActiveSupport::TestCase
  setup do
    @owner_user = create(:user)
    @collab_user = create(:user)
    @member_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      @owner_tu = create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: @owner_person)
      @collab_person = create(:person, tenant: @tenant)
      @collab_tu = create(:tenant_user, tenant: @tenant, user: @collab_user, role: :member, person: @collab_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @suggestion_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Critical Thinking")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.add_collaborator(@framework_id, @collab_person.id.to_s, "collaborator", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "seed")
      # A pending suggestion to discuss (collaborator-authored → stays pending).
      handler.suggest_edit(@framework_id, @suggestion_id, "capability", @cap_id,
                           "description", "Weighs long-term impact", @collab_person.id.to_s,
                           mode: :suggesting)
    end

    @owner_ctx = AuthorizationContext.new(user: @owner_user, tenant_user: @owner_tu, person: @owner_person)
    @collab_ctx = AuthorizationContext.new(user: @collab_user, tenant_user: @collab_tu, person: @collab_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def comment(ctx, params)
    Operations::Frameworks::CommentOnSuggestion.call(context: ctx, params: params)
  end

  context "as a suggest-rights collaborator" do
    should "post a top-level comment" do
      ActsAsTenant.with_tenant(@tenant) do
        result = comment(@owner_ctx, {
          framework_id: @framework_id, suggestion_id: @suggestion_id,
          body: "Is 'long-term' the right frame?"
        })

        row = FrameworkState::SuggestionComment.find(result[:comment_id])
        assert_equal @suggestion_id, row.suggestion_id
        assert_equal @owner_person.id, row.author_id
        assert_equal "active", row.status
        assert_nil result[:parent_id]
        assert result[:posted_at].present?
      end
    end

    should "post a reply to an existing comment" do
      ActsAsTenant.with_tenant(@tenant) do
        top = comment(@owner_ctx, {
          framework_id: @framework_id, suggestion_id: @suggestion_id, body: "Top"
        })

        reply = comment(@collab_ctx, {
          framework_id: @framework_id, suggestion_id: @suggestion_id,
          body: "Replying", parent_id: top[:comment_id]
        })

        assert_equal top[:comment_id], reply[:parent_id]
      end
    end

    should "keep the thread open on a resolved suggestion" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.approve_suggestion(
          @framework_id, @suggestion_id, @owner_person.id.to_s
        )

        result = comment(@collab_ctx, {
          framework_id: @framework_id, suggestion_id: @suggestion_id, body: "Glad this landed"
        })

        assert result[:comment_id].present?
      end
    end

    should "reject a blank body" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          comment(@owner_ctx, {
            framework_id: @framework_id, suggestion_id: @suggestion_id, body: "   "
          })
        end
      end
    end

    should "reject an unknown suggestion as not found" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          comment(@owner_ctx, {
            framework_id: @framework_id, suggestion_id: SecureRandom.uuid_v7, body: "Hello"
          })
        end
      end
    end

    should "reject a reply to an unknown parent" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          comment(@owner_ctx, {
            framework_id: @framework_id, suggestion_id: @suggestion_id,
            body: "Reply", parent_id: SecureRandom.uuid_v7
          })
        end
        assert_match(/parent comment not found/, error.message)
      end
    end

    should "reject a reply to a deleted parent" do
      ActsAsTenant.with_tenant(@tenant) do
        top = comment(@owner_ctx, {
          framework_id: @framework_id, suggestion_id: @suggestion_id, body: "Top"
        })
        Frameworks::CommandHandler.new.delete_suggestion_comment(
          @framework_id, top[:comment_id], deleted_by_id: @owner_person.id.to_s
        )

        assert_raises(Operations::Base::ParameterError) do
          comment(@collab_ctx, {
            framework_id: @framework_id, suggestion_id: @suggestion_id,
            body: "Reply", parent_id: top[:comment_id]
          })
        end
      end
    end

    should "reject a reply whose parent belongs to a different suggestion" do
      ActsAsTenant.with_tenant(@tenant) do
        other_suggestion = SecureRandom.uuid_v7
        Frameworks::CommandHandler.new.suggest_edit(
          @framework_id, other_suggestion, "capability", @cap_id,
          "name", "Systems Thinking", @collab_person.id.to_s, mode: :suggesting
        )
        top = comment(@owner_ctx, {
          framework_id: @framework_id, suggestion_id: other_suggestion, body: "On the other"
        })

        error = assert_raises(Operations::Base::ParameterError) do
          comment(@owner_ctx, {
            framework_id: @framework_id, suggestion_id: @suggestion_id,
            body: "Cross-thread", parent_id: top[:comment_id]
          })
        end
        assert_match(/different suggestion/, error.message)
      end
    end
  end

  context "as a plain tenant member (no collaborator role)" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          comment(@member_ctx, {
            framework_id: @framework_id, suggestion_id: @suggestion_id, body: "Hi"
          })
        end
      end
    end
  end
end

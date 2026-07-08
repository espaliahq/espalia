# frozen_string_literal: true

require "test_helper"

# EditSuggestionComment is author-only: the author revises their comment's
# body; anyone else — including a tenant admin — is denied, as is any edit
# of a deleted comment.
class Operations::Frameworks::EditSuggestionCommentTest < ActiveSupport::TestCase
  setup do
    @author_user = create(:user)
    @admin_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @author_person = create(:person, tenant: @tenant, email: @author_user.email)
      @author_tu = create(:tenant_user, tenant: @tenant, user: @author_user, role: :member, person: @author_person)
      @admin_person = create(:person, tenant: @tenant)
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)

      @framework_id = SecureRandom.uuid_v7
      @suggestion_id = SecureRandom.uuid_v7
      @comment_id = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      cat_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Critical Thinking")
      handler.add_collaborator(@framework_id, @author_person.id.to_s, "collaborator",
                               added_by: @author_person.id.to_s)
      handler.suggest_edit(@framework_id, @suggestion_id, "capability", cap_id,
                           "description", "Proposed", @author_person.id.to_s, mode: :suggesting)
      handler.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
                                    body: "Original", author_id: @author_person.id.to_s)
    end

    @author_ctx = AuthorizationContext.new(user: @author_user, tenant_user: @author_tu, person: @author_person)
    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
  end

  def edit_comment(ctx, params)
    Operations::Frameworks::EditSuggestionComment.call(context: ctx, params: params)
  end

  should "revise the author's own comment" do
    ActsAsTenant.with_tenant(@tenant) do
      result = edit_comment(@author_ctx, {
        framework_id: @framework_id, comment_id: @comment_id, body: "Revised"
      })

      assert_equal "Revised", result[:body]
      assert result[:edited_at].present?
      assert_equal "Revised", FrameworkState::SuggestionComment.find(@comment_id).body
    end
  end

  should "deny a non-author — even a tenant admin" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_raises(Pundit::NotAuthorizedError) do
        edit_comment(@admin_ctx, {
          framework_id: @framework_id, comment_id: @comment_id, body: "Hijack"
        })
      end
    end
  end

  should "deny editing a deleted comment" do
    ActsAsTenant.with_tenant(@tenant) do
      Frameworks::CommandHandler.new.delete_suggestion_comment(
        @framework_id, @comment_id, deleted_by_id: @author_person.id.to_s
      )

      assert_raises(Pundit::NotAuthorizedError) do
        edit_comment(@author_ctx, {
          framework_id: @framework_id, comment_id: @comment_id, body: "Too late"
        })
      end
    end
  end

  should "reject a blank body" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_raises(Operations::Base::ParameterError) do
        edit_comment(@author_ctx, {
          framework_id: @framework_id, comment_id: @comment_id, body: ""
        })
      end
    end
  end

  should "read an unknown comment as not found" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_raises(ActiveRecord::RecordNotFound) do
        edit_comment(@author_ctx, {
          framework_id: @framework_id, comment_id: SecureRandom.uuid_v7, body: "x"
        })
      end
    end
  end
end

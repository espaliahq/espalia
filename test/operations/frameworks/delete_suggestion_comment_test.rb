# frozen_string_literal: true

require "test_helper"

# DeleteSuggestionComment soft-deletes: the author or a tenant admin may
# delete; the row survives with status "deleted"; double deletes and
# unrelated collaborators are denied.
class Operations::Frameworks::DeleteSuggestionCommentTest < ActiveSupport::TestCase
  setup do
    @author_user = create(:user)
    @admin_user = create(:user)
    @other_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @author_person = create(:person, tenant: @tenant, email: @author_user.email)
      @author_tu = create(:tenant_user, tenant: @tenant, user: @author_user, role: :member, person: @author_person)
      @admin_person = create(:person, tenant: @tenant)
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      @other_person = create(:person, tenant: @tenant)
      @other_tu = create(:tenant_user, tenant: @tenant, user: @other_user, role: :member, person: @other_person)

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
      handler.add_collaborator(@framework_id, @other_person.id.to_s, "collaborator",
                               added_by: @author_person.id.to_s)
      handler.suggest_edit(@framework_id, @suggestion_id, "capability", cap_id,
                           "description", "Proposed", @author_person.id.to_s, mode: :suggesting)
      handler.comment_on_suggestion(@framework_id, @suggestion_id, @comment_id,
                                    body: "Original", author_id: @author_person.id.to_s)
    end

    @author_ctx = AuthorizationContext.new(user: @author_user, tenant_user: @author_tu, person: @author_person)
    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    @other_ctx = AuthorizationContext.new(user: @other_user, tenant_user: @other_tu, person: @other_person)
  end

  def delete_comment(ctx, params)
    Operations::Frameworks::DeleteSuggestionComment.call(context: ctx, params: params)
  end

  should "soft-delete for the author" do
    ActsAsTenant.with_tenant(@tenant) do
      result = delete_comment(@author_ctx, {
        framework_id: @framework_id, comment_id: @comment_id, reason: "off-topic"
      })

      assert_equal "deleted", result[:status]
      row = FrameworkState::SuggestionComment.find(@comment_id)
      assert row.deleted?
      assert_equal "off-topic", row.deletion_reason
    end
  end

  should "soft-delete for a tenant admin" do
    ActsAsTenant.with_tenant(@tenant) do
      result = delete_comment(@admin_ctx, {
        framework_id: @framework_id, comment_id: @comment_id
      })

      assert_equal "deleted", result[:status]
    end
  end

  should "deny an unrelated collaborator" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_raises(Pundit::NotAuthorizedError) do
        delete_comment(@other_ctx, { framework_id: @framework_id, comment_id: @comment_id })
      end
    end
  end

  should "deny a second delete" do
    ActsAsTenant.with_tenant(@tenant) do
      delete_comment(@author_ctx, { framework_id: @framework_id, comment_id: @comment_id })

      assert_raises(Pundit::NotAuthorizedError) do
        delete_comment(@author_ctx, { framework_id: @framework_id, comment_id: @comment_id })
      end
    end
  end

  should "read an unknown comment as not found" do
    ActsAsTenant.with_tenant(@tenant) do
      assert_raises(ActiveRecord::RecordNotFound) do
        delete_comment(@author_ctx, { framework_id: @framework_id, comment_id: SecureRandom.uuid_v7 })
      end
    end
  end
end

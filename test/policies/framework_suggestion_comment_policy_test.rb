# frozen_string_literal: true

require "test_helper"

# FrameworkSuggestionCommentPolicy: author-only edits; author + tenant
# admin deletes; nothing on a deleted comment; no person → denied.
class FrameworkSuggestionCommentPolicyTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant)
      @other = create(:person, tenant: @tenant)
      @comment = FrameworkState::SuggestionComment.create!(
        id: SecureRandom.uuid_v7,
        tenant: @tenant,
        framework_id: SecureRandom.uuid_v7,
        suggestion_id: SecureRandom.uuid_v7,
        author_id: @author.id,
        body: "Original",
        status: "active",
        posted_at: Time.current
      )
    end
  end

  def context_for(person:, role: :member)
    user = create(:user)
    tu = ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: user, role: role, person: person)
    end
    AuthorizationContext.new(user: user, tenant_user: tu, person: person)
  end

  context "as the author" do
    should "permit update and destroy" do
      ctx = context_for(person: @author)
      assert FrameworkSuggestionCommentPolicy.new(ctx, @comment).update?
      assert FrameworkSuggestionCommentPolicy.new(ctx, @comment).destroy?
    end

    should "deny both on a deleted comment" do
      ActsAsTenant.with_tenant(@tenant) { @comment.update!(status: "deleted") }
      ctx = context_for(person: @author)
      assert_not FrameworkSuggestionCommentPolicy.new(ctx, @comment).update?
      assert_not FrameworkSuggestionCommentPolicy.new(ctx, @comment).destroy?
    end
  end

  context "as a tenant admin (non-author)" do
    should "deny update but permit destroy" do
      ctx = context_for(person: @other, role: :admin)
      assert_not FrameworkSuggestionCommentPolicy.new(ctx, @comment).update?
      assert FrameworkSuggestionCommentPolicy.new(ctx, @comment).destroy?
    end
  end

  context "as an unrelated member" do
    should "deny both" do
      ctx = context_for(person: @other)
      assert_not FrameworkSuggestionCommentPolicy.new(ctx, @comment).update?
      assert_not FrameworkSuggestionCommentPolicy.new(ctx, @comment).destroy?
    end
  end

  context "without a linked person" do
    should "deny both — even for a tenant admin" do
      ctx = context_for(person: nil, role: :admin)
      assert_not FrameworkSuggestionCommentPolicy.new(ctx, @comment).update?
      assert_not FrameworkSuggestionCommentPolicy.new(ctx, @comment).destroy?
    end
  end
end

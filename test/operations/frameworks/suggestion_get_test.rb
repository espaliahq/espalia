# frozen_string_literal: true

require "test_helper"

# SuggestionGet returns the full suggestion — proposal, resolution, and the
# discussion thread with replies nested one level (active comments only).
class Operations::Frameworks::SuggestionGetTest < ActiveSupport::TestCase
  setup do
    @owner_user = create(:user)
    @member_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      @owner_tu = create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: @owner_person)
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
      handler.publish_version(@framework_id, "seed")
      handler.suggest_edit(@framework_id, @suggestion_id, "capability", @cap_id,
                           "description", "Weighs long-term impact", @owner_person.id.to_s,
                           mode: :suggesting, rationale: "clearer")

      # Thread: top-level + reply + a deleted top-level (must be omitted).
      @top_id = SecureRandom.uuid_v7
      @reply_id = SecureRandom.uuid_v7
      doomed_id = SecureRandom.uuid_v7
      handler.comment_on_suggestion(@framework_id, @suggestion_id, @top_id,
                                    body: "Is this the right frame?", author_id: @owner_person.id.to_s)
      handler.comment_on_suggestion(@framework_id, @suggestion_id, @reply_id,
                                    body: "I think so", author_id: @owner_person.id.to_s,
                                    parent_id: @top_id)
      handler.comment_on_suggestion(@framework_id, @suggestion_id, doomed_id,
                                    body: "Doomed", author_id: @owner_person.id.to_s)
      handler.delete_suggestion_comment(@framework_id, doomed_id, deleted_by_id: @owner_person.id.to_s)
    end

    @owner_ctx = AuthorizationContext.new(user: @owner_user, tenant_user: @owner_tu, person: @owner_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def suggestion_get(ctx, params)
    Operations::Frameworks::SuggestionGet.call(context: ctx, params: params)
  end

  context "as a suggest-rights collaborator" do
    should "return the proposal, resolution fields, and the nested thread" do
      ActsAsTenant.with_tenant(@tenant) do
        result = suggestion_get(@owner_ctx, {
          framework_id: @framework_id, suggestion_id: @suggestion_id
        })

        assert_equal "pending", result[:status]
        assert_equal "edit", result[:kind]
        assert_equal "capability", result[:target_entity_type]
        assert_equal "Weighs long-term impact", result[:suggested_value]
        assert_equal "clearer", result[:rationale]
        assert_equal @owner_person.name, result[:author][:name]
        assert_nil result[:reviewed_by]

        # Deleted top-level omitted; reply nested under its parent.
        assert_equal [ @top_id ], result[:comments].map { |c| c[:id] }
        assert_equal [ @reply_id ], result[:comments].first[:replies].map { |r| r[:id] }
        assert_equal "I think so", result[:comments].first[:replies].first[:body]
      end
    end

    should "nest a reply-to-a-reply under the thread's top-level comment" do
      ActsAsTenant.with_tenant(@tenant) do
        deep_id = SecureRandom.uuid_v7
        Frameworks::CommandHandler.new.comment_on_suggestion(
          @framework_id, @suggestion_id, deep_id,
          body: "Going deeper", author_id: @owner_person.id.to_s, parent_id: @reply_id
        )

        result = suggestion_get(@owner_ctx, {
          framework_id: @framework_id, suggestion_id: @suggestion_id
        })

        # Depth is unbounded in data; the payload groups by root ancestor.
        assert_equal [ @reply_id, deep_id ],
                     result[:comments].first[:replies].map { |r| r[:id] }
      end
    end

    should "carry the resolution after an approve" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.approve_suggestion(
          @framework_id, @suggestion_id, @owner_person.id.to_s, comment: "landing it"
        )

        result = suggestion_get(@owner_ctx, {
          framework_id: @framework_id, suggestion_id: @suggestion_id
        })

        assert_equal "approved", result[:status]
        assert_equal "landing it", result[:reviewer_comment]
        assert_equal @owner_person.name, result[:reviewed_by][:name]
        assert result[:reviewed_at].present?
      end
    end

    should "read an unknown suggestion as not found" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          suggestion_get(@owner_ctx, {
            framework_id: @framework_id, suggestion_id: SecureRandom.uuid_v7
          })
        end
      end
    end
  end

  context "as a plain tenant member (no collaborator role)" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          suggestion_get(@member_ctx, {
            framework_id: @framework_id, suggestion_id: @suggestion_id
          })
        end
      end
    end
  end
end

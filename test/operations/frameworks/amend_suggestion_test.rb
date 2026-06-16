# frozen_string_literal: true

require "test_helper"

# Amending a pending suggested edit revises the proposed value. Author-only:
# the original author can amend; a different person is denied.
class Operations::Frameworks::AmendSuggestionTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @author_user = create(:user)
    @other_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @author = create(:person, tenant: @tenant)
      @other = create(:person, tenant: @tenant)
      @author_tu = create(:tenant_user, tenant: @tenant, user: @author_user, role: :member, person: @author)
      @other_tu = create(:tenant_user, tenant: @tenant, user: @other_user, role: :member, person: @other)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Original name")
      handler.publish_version(@framework_id, "seed")

      @suggestion_id = SecureRandom.uuid_v7
      handler.suggest_edit(
        @framework_id, @suggestion_id, "capability", @cap_id,
        "name", "First proposal", @author.id.to_s, mode: :suggesting
      )
    end

    @author_ctx = AuthorizationContext.new(user: @author_user, tenant_user: @author_tu, person: @author)
    @other_ctx = AuthorizationContext.new(user: @other_user, tenant_user: @other_tu, person: @other)
  end

  def suggestion
    FrameworkState::SuggestedEdit.find_by!(suggestion_id: @suggestion_id)
  end

  context "as the author" do
    should "revise the proposed value" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::AmendSuggestion.call(
          context: @author_ctx,
          params: {
            framework_id: @framework_id, suggestion_id: @suggestion_id,
            suggested_value: "Second proposal", rationale: "clearer"
          }
        )

        assert_equal "pending", suggestion.status
        assert_equal "Second proposal", suggestion.suggested_value
      end
    end
  end

  context "as a different person" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::AmendSuggestion.call(
            context: @other_ctx,
            params: {
              framework_id: @framework_id, suggestion_id: @suggestion_id,
              suggested_value: "Hijacked"
            }
          )
        end
        assert_equal "First proposal", suggestion.suggested_value
      end
    end
  end
end

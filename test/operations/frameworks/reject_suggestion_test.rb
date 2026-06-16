# frozen_string_literal: true

require "test_helper"

# Rejecting a pending suggested edit through the Operations layer flips the
# read-model status to rejected without applying the change, and records the
# optional reviewer comment. Authority is tier-based; a member is denied.
class Operations::Frameworks::RejectSuggestionTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      @author = create(:person, tenant: @tenant)

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
        "name", "Proposed name", @author.id.to_s, mode: :suggesting
      )
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def suggestion
    FrameworkState::SuggestedEdit.find_by!(suggestion_id: @suggestion_id)
  end

  context "as a tenant admin" do
    should "reject the suggestion and leave the entity unchanged" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::RejectSuggestion.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, suggestion_id: @suggestion_id, comment: "off-strategy" }
        )

        assert_equal "rejected", result[:status]
        assert_equal "rejected", suggestion.status
        assert_equal "Original name", FrameworkState::Capability.find_by(capability_id: @cap_id).name
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::RejectSuggestion.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, suggestion_id: @suggestion_id }
          )
        end
        assert_equal "pending", suggestion.status
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

# Requesting a clarification anchors a non-proposal suggestion on the cell —
# the expectation when one exists, else the capability + level_ordinal.
class Operations::Frameworks::RequestClarificationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @exp_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.set_behavioural_expectation(@framework_id, @exp_id, SecureRandom.uuid_v7, @cap_id, 4, "Shapes direction")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  context "as a tenant admin with a linked person" do
    should "anchor on the expectation when the cell has one" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::RequestClarification.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, capability_id: @cap_id,
                    level_ordinal: 4, rationale: "Raters read this three ways" }
        )

        assert_equal "behavioural_expectation", result[:target_entity_type]
        row = FrameworkState::SuggestedEdit.find_by!(suggestion_id: result[:suggestion_id])
        assert_equal "clarification", row.kind
        assert_equal "pending", row.status
        assert_equal @exp_id, row.target_entity_id
        assert_equal "Shapes direction", row.current_value
      end
    end

    should "anchor on the capability with the level in proposed_attributes when the cell is empty" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::RequestClarification.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, capability_id: @cap_id,
                    level_ordinal: 6, rationale: "Nothing defined at L6" }
        )

        assert_equal "capability", result[:target_entity_type]
        row = FrameworkState::SuggestedEdit.find_by!(suggestion_id: result[:suggestion_id])
        assert_equal @cap_id, row.target_entity_id
        assert_equal 6, row.proposed_attributes["level_ordinal"]
      end
    end

    should "reject a blank rationale" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::RequestClarification.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, capability_id: @cap_id,
                      level_ordinal: 4, rationale: "  " }
          )
        end
      end
    end
  end

  context "as a plain tenant member with no collaborator role" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::RequestClarification.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, capability_id: @cap_id,
                      level_ordinal: 4, rationale: "?" }
          )
        end
      end
    end
  end
end

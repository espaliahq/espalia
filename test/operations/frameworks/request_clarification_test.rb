# frozen_string_literal: true

require "test_helper"

# Requesting a clarification anchors a non-proposal suggestion on the entity —
# the illustration when one is named, else the cell's expectation, else the
# capability (with the level_ordinal when the question is cell-scoped).
class Operations::Frameworks::RequestClarificationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      @member_person = create(:person, tenant: @tenant, email: @member_user.email)
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @exp_id = SecureRandom.uuid_v7
      @illustration_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      family_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, family_id, "Engineering")
      handler.add_role(@framework_id, role_id, family_id, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, role_id, 4, "Senior Engineer", "E4")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Strategic Thinking")
      handler.set_behavioural_expectation(@framework_id, @exp_id, SecureRandom.uuid_v7, @cap_id, 4, "Shapes direction")
      handler.add_role_illustration(@framework_id, @illustration_id, SecureRandom.uuid_v7, @exp_id,
                                    role_id, 1, "Leads third-party integrations")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    # A linked person WITH no collaborator role — so the denial below is
    # about the missing suggest rights, not a missing person.
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: @member_person)
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

    should "anchor on the illustration, taking the level from its expectation" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::RequestClarification.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, illustration_id: @illustration_id,
                    rationale: "Is third-party integration really an L4 example?" }
        )

        assert_equal "role_illustration", result[:target_entity_type]
        assert_equal @illustration_id, result[:illustration_id]
        assert_equal @cap_id, result[:capability_id]
        assert_equal 4, result[:level_ordinal]

        row = FrameworkState::SuggestedEdit.find_by!(suggestion_id: result[:suggestion_id])
        assert_equal "clarification", row.kind
        assert_equal @illustration_id, row.target_entity_id
        assert_equal 4, row.proposed_attributes["level_ordinal"]
      end
    end

    should "not find an illustration belonging to another framework" do
      other_illustration_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        other_framework_id = SecureRandom.uuid_v7
        other_cap_id = SecureRandom.uuid_v7
        other_exp_id = SecureRandom.uuid_v7
        handler = Frameworks::CommandHandler.new
        handler.create_framework(other_framework_id, "Design")
        family_id = SecureRandom.uuid_v7
        role_id = SecureRandom.uuid_v7
        handler.add_role_family(other_framework_id, family_id, "Design")
        handler.add_role(other_framework_id, role_id, family_id, "Product Designer", "PD", "ic")
        handler.add_level(other_framework_id, SecureRandom.uuid_v7, role_id, 4, "Senior Designer", "PD4")
        cat_id = SecureRandom.uuid_v7
        handler.add_capability_category(other_framework_id, cat_id, "Craft")
        handler.add_capability(other_framework_id, other_cap_id, SecureRandom.uuid_v7, cat_id, "Visual Design")
        handler.set_behavioural_expectation(other_framework_id, other_exp_id, SecureRandom.uuid_v7,
                                            other_cap_id, 4, "Sets the visual bar")
        handler.add_role_illustration(other_framework_id, other_illustration_id, SecureRandom.uuid_v7,
                                      other_exp_id, role_id, 1, "Runs the design system")
        handler.publish_version(other_framework_id, "seed")

        assert_raises(ActiveRecord::RecordNotFound) do
          Operations::Frameworks::RequestClarification.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, illustration_id: other_illustration_id,
                      rationale: "Whose example is this?" }
          )
        end
      end
    end

    should "anchor on the capability with no level when the question is capability-wide" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::RequestClarification.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, capability_id: @cap_id,
                    rationale: "Is this capability distinct from Judgement?" }
        )

        assert_equal "capability", result[:target_entity_type]
        assert_nil result[:level_ordinal]
        row = FrameworkState::SuggestedEdit.find_by!(suggestion_id: result[:suggestion_id])
        assert_equal @cap_id, row.target_entity_id
        assert_empty row.proposed_attributes
      end
    end

    should "reject a request naming neither a capability nor an illustration" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::RequestClarification.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, rationale: "About what?" }
          )
        end
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

# frozen_string_literal: true

require "test_helper"

# Resolving a clarification flips it to "resolved" with the note and optional
# resulting-suggestion link; authority is expectation-tier.
class Operations::Frameworks::ResolveClarificationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      @author = create(:person, tenant: @tenant)

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

      @sid = SecureRandom.uuid_v7
      handler.request_clarification(
        @framework_id, @sid, "behavioural_expectation", @exp_id,
        author_id: @author.id.to_s, rationale: "What does this mean?"
      )

      # A concrete rewording suggestion the clarification can link as its outcome.
      @rsid = SecureRandom.uuid_v7
      handler.suggest_edit(
        @framework_id, @rsid, "behavioural_expectation", @exp_id,
        "description", "Clearer wording", @author.id.to_s, mode: :suggesting
      )
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def clarification
    FrameworkState::SuggestedEdit.find_by!(suggestion_id: @sid)
  end

  context "as a tenant admin" do
    should "resolve with the note and resulting suggestion" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ResolveClarification.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, suggestion_id: @sid,
                    note: "Reworded L4 — see the linked suggestion", resulting_suggestion_id: @rsid }
        )

        assert_equal "resolved", result[:status]
        assert_equal "resolved", clarification.status
        assert_equal "Reworded L4 — see the linked suggestion", clarification.reviewer_comment
        assert_equal @rsid, clarification.resulting_suggestion_id
      end
    end

    should "reject a dangling resulting_suggestion_id" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::ResolveClarification.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, suggestion_id: @sid,
                      note: "n", resulting_suggestion_id: SecureRandom.uuid_v7 }
          )
        end
        assert_equal "pending", clarification.status
      end
    end

    should "refuse to resolve a proposal-kind suggestion" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ResolveClarification.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, suggestion_id: @rsid, note: "n" }
          )
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ResolveClarification.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, suggestion_id: @sid, note: "n" }
          )
        end
        assert_equal "pending", clarification.status
      end
    end
  end
end

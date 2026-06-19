# frozen_string_literal: true

require "test_helper"

# SetBehaviouralExpectation authors an expectation on an empty capability × level
# cell, following the suggest/approve path: an author with approval authority in
# editing mode applies it directly (shape-changing → draft, deferred to publish);
# a suggest-only collaborator (or suggesting mode) proposes it as a pending
# behavioural_expectation creation suggestion.
class Operations::Frameworks::SetBehaviouralExpectationTest < ActiveSupport::TestCase
  setup do
    @owner_user = create(:user)
    @collab_user = create(:user)
    @member_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      @owner_tu = create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: @owner_person)
      # Suggest rights, but no approval authority over expectations.
      @collab_person = create(:person, tenant: @tenant)
      @collab_tu = create(:tenant_user, tenant: @tenant, user: @collab_user, role: :member, person: @collab_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 1, "Asks clarifying questions")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.add_collaborator(@framework_id, @collab_person.id.to_s, "collaborator", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "seed")
    end

    @owner_ctx = AuthorizationContext.new(user: @owner_user, tenant_user: @owner_tu, person: @owner_person)
    @collab_ctx = AuthorizationContext.new(user: @collab_user, tenant_user: @collab_tu, person: @collab_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def pending_creates
    FrameworkState::SuggestedEdit.where(framework_id: @framework_id, kind: "create",
                                        target_entity_type: "behavioural_expectation", status: "pending")
  end

  def set_expectation(ctx, params)
    Operations::Frameworks::SetBehaviouralExpectation.call(context: ctx, params: params)
  end

  context "as an author with approval authority (owner), editing mode" do
    should "apply directly, auto-open a draft, and land in the read model on publish" do
      ActsAsTenant.with_tenant(@tenant) do
        result = set_expectation(@owner_ctx, {
          framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 2,
          description: "Identifies root causes", mode: "editing"
        })

        assert result[:applied], "owner in editing mode applies directly"
        assert framework.draft_in_progress
        assert_empty pending_creates
        # Shape-changing — deferred until publish.
        assert_nil FrameworkState::BehaviouralExpectation.find_by(capability_id: @cap_id, level_ordinal: 2)

        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")

        exp = FrameworkState::BehaviouralExpectation.find_by(capability_id: @cap_id, level_ordinal: 2)
        assert_not_nil exp
        assert_equal "Identifies root causes", exp.description
      end
    end

    should "reject authoring over a cell that already has an expectation" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          set_expectation(@owner_ctx, { framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 1, description: "Dup" })
        end
        assert_match(/already has an expectation/i, error.message)
        assert_not framework.draft_in_progress
      end
    end

    should "reject a blank description" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          set_expectation(@owner_ctx, { framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 2, description: "   " })
        end
      end
    end

    should "propose (not apply) in suggesting mode" do
      ActsAsTenant.with_tenant(@tenant) do
        result = set_expectation(@owner_ctx, {
          framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 2,
          description: "Identifies root causes", mode: "suggesting"
        })

        assert_not result[:applied], "suggesting mode never applies directly"
        assert_equal 1, pending_creates.count
      end
    end
  end

  context "as a suggest-only collaborator, editing mode" do
    should "land as a pending suggestion, not a direct apply" do
      ActsAsTenant.with_tenant(@tenant) do
        result = set_expectation(@collab_ctx, {
          framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 2,
          description: "Identifies root causes", mode: "editing"
        })

        assert_not result[:applied], "no approval authority → proposed, not applied"
        assert_equal 1, pending_creates.count
        assert_equal @collab_person.id, pending_creates.first.author_id
      end
    end
  end

  context "as a tenant member with no suggest rights" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          set_expectation(@member_ctx, { framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 2, description: "x" })
        end
      end
    end
  end
end

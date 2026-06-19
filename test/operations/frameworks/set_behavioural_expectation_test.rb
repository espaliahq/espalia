# frozen_string_literal: true

require "test_helper"

# SetBehaviouralExpectation authors an expectation in an empty capability × level
# cell (shape-changing: auto-opens a draft). The new expectation is deferred from
# the published read model until publish.
class Operations::Frameworks::SetBehaviouralExpectationTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(@framework_id, SecureRandom.uuid_v7, @cap_id, @role_id)
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 1, "Asks clarifying questions")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def set_expectation(ctx, params)
    Operations::Frameworks::SetBehaviouralExpectation.call(context: ctx, params: params)
  end

  context "as a tenant admin" do
    should "author an expectation on an empty cell, auto-open a draft, and apply on publish" do
      ActsAsTenant.with_tenant(@tenant) do
        result = set_expectation(@admin_ctx, {
          framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 2,
          description: "Identifies root causes"
        })

        assert_equal 2, result[:level_ordinal]
        assert framework.draft_in_progress

        # Shape-changing — deferred until publish.
        assert_nil FrameworkState::BehaviouralExpectation.find_by(expectation_id: result[:expectation_id])

        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")

        exp = FrameworkState::BehaviouralExpectation.find_by(expectation_id: result[:expectation_id])
        assert_not_nil exp
        assert_equal "Identifies root causes", exp.description
        assert_equal 2, exp.level_ordinal
      end
    end

    should "reject authoring over a cell that already has an expectation" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          set_expectation(@admin_ctx, {
            framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 1, description: "Dup"
          })
        end
        assert_match(/already has an expectation/i, error.message)
        assert_not framework.draft_in_progress
      end
    end

    should "reject a blank description" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          set_expectation(@admin_ctx, {
            framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 2, description: "   "
          })
        end
        assert_match(/can't be blank/i, error.message)
      end
    end

    should "raise when the capability is not in this framework" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          set_expectation(@admin_ctx, {
            framework_id: @framework_id, capability_id: SecureRandom.uuid_v7, level_ordinal: 2, description: "X"
          })
        end
      end
    end
  end

  context "as a tenant member (no edit rights)" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          set_expectation(@member_ctx, {
            framework_id: @framework_id, capability_id: @cap_id, level_ordinal: 2, description: "X"
          })
        end
      end
    end
  end
end

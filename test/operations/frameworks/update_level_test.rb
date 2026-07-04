# frozen_string_literal: true

require "test_helper"

# UpdateLevel edits a level's title / code. Shape-preserving — applies to the
# published read model immediately and opens no draft. (Ordinal moves and the
# is_entry flag are out of scope — see the operation's docstring.)
class Operations::Frameworks::UpdateLevelTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      @level_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_role_family(@framework_id, @rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, @rf_id, "Software Engineer", "E", "ic")
      # add_level is shape-changing — the bootstrapped v1 draft is open here.
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Software Engineer I", "E1")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def level
    FrameworkState::Level.find_by(level_id: @level_id)
  end

  context "as a tenant admin" do
    should "update title / code live without opening a draft" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::UpdateLevel.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, level_id: @level_id,
                    title: "Engineer I", code: "ENG1" }
        )

        assert_equal "Engineer I", result[:title]
        assert_equal "Engineer I", level.title
        assert_equal "ENG1", level.code
        assert_not framework.draft_in_progress
      end
    end

    should "raise when no updatable field is supplied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::UpdateLevel.call(
            context: @admin_ctx, params: { framework_id: @framework_id, level_id: @level_id }
          )
        end
      end
    end

    should "flip is_entry on its own — false is a supplied value, not 'nothing to update'" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::UpdateLevel.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, level_id: @level_id, is_entry: true }
        )
        assert level.is_entry

        Operations::Frameworks::UpdateLevel.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, level_id: @level_id, is_entry: false }
        )
        assert_not level.is_entry
        assert_not framework.draft_in_progress
      end
    end

    should "cast a web-form is_entry string" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::UpdateLevel.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, level_id: @level_id, is_entry: "1" }
        )
        assert level.is_entry
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::UpdateLevel.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, level_id: @level_id, title: "Nope" }
          )
        end
      end
    end
  end
end

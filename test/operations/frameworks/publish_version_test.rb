# frozen_string_literal: true

require "test_helper"

# End-to-end check that the PublishVersion Operation routes through to the
# real command handler: the bootstrap v1 draft publishes, the read model's
# version advances and the draft clears, and publishing again (no draft)
# raises. Also pins the policy gate — a plain tenant member is denied.
class Operations::Frameworks::PublishVersionTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      Frameworks::CommandHandler.new.create_framework(@framework_id, "Eng Framework")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "publish the bootstrap v1 draft and advance the version" do
      ActsAsTenant.with_tenant(@tenant) do
        assert framework.draft_in_progress
        assert_equal 0, framework.current_published_version

        result = Operations::Frameworks::PublishVersion.call(
          context: @admin_ctx, params: { framework_id: @framework_id }
        )

        assert_equal @framework_id, result[:framework_id]
        assert_equal 1, result[:published_version]
        assert_equal 1, framework.current_published_version
        assert_not framework.draft_in_progress
      end
    end

    should "raise when there is no draft in progress" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::PublishVersion.call(
          context: @admin_ctx, params: { framework_id: @framework_id }
        )

        error = assert_raises(RuntimeError) do
          Operations::Frameworks::PublishVersion.call(
            context: @admin_ctx, params: { framework_id: @framework_id }
          )
        end
        assert_match(/no draft/i, error.message)
      end
    end

    should "refuse to publish while an archived capability lacks a migration mapping" do
      ActsAsTenant.with_tenant(@tenant) do
        handler = Frameworks::CommandHandler.new
        cat_id = SecureRandom.uuid_v7
        cap_id = SecureRandom.uuid_v7
        handler.add_capability_category(@framework_id, cat_id, "Thinking")
        handler.add_capability(@framework_id, cap_id, SecureRandom.uuid_v7, cat_id, "Legacy")
        handler.publish_version(@framework_id, "seed")                 # v1; cap pre-draft
        handler.archive_capability(@framework_id, cap_id, reason: "x") # auto-opens v2, no mapping

        error = assert_raises(RuntimeError) do
          Operations::Frameworks::PublishVersion.call(
            context: @admin_ctx, params: { framework_id: @framework_id }
          )
        end
        assert_match(/lack migration mappings/i, error.message)
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::PublishVersion.call(
            context: @member_ctx, params: { framework_id: @framework_id }
          )
        end
      end
    end
  end
end

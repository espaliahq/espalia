# frozen_string_literal: true

require "test_helper"

# End-to-end check of the as-we-go archive flow: archiving a pre-draft
# capability auto-opens a draft, records the migration mapping in the same
# action, and (once published) marks the capability archived. Without a
# mapping the publish gate blocks — proving why mapping-as-we-go matters.
class Operations::Frameworks::ArchiveCapabilityTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @survivor_stable = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, cat_id, "Legacy Systems")
      handler.add_capability(@framework_id, SecureRandom.uuid_v7, @survivor_stable, cat_id, "Platform Eng")
      handler.publish_version(@framework_id, "seed") # v1; no draft, caps are pre-draft
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "archive with a mapping, auto-open a draft, and apply on publish" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ArchiveCapability.call(
          context: @admin_ctx,
          params: {
            framework_id: @framework_id, capability_id: @cap_id, reason: "Retired",
            mapping_type: "evolved", to_stable_id: @survivor_stable
          }
        )
        assert_equal @cap_id, result[:capability_id]
        assert_equal "evolved", result[:mapping_type]

        # Draft auto-opened; the mapping is recorded for the draft version.
        assert framework.draft_in_progress
        assert_equal 2, framework.draft_version
        mapping = FrameworkState::MigrationMapping.find_by(
          framework_id: @framework_id, from_stable_id: result[:stable_id]
        )
        assert_not_nil mapping
        assert_equal "evolved", mapping.mapping_type
        assert_equal @survivor_stable, mapping.to_stable_id

        # Archive is shape-changing — deferred in the published view until publish.
        assert_equal "active", FrameworkState::Capability.find_by(capability_id: @cap_id).status

        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")
        assert_equal "archived", FrameworkState::Capability.find_by(capability_id: @cap_id).status
      end
    end

    should "archive without a mapping but then block publish (mapping required)" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::ArchiveCapability.call(
          context: @admin_ctx, params: { framework_id: @framework_id, capability_id: @cap_id, reason: "Retired" }
        )

        error = assert_raises(RuntimeError) do
          Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")
        end
        assert_match(/lack migration mappings/i, error.message)
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ArchiveCapability.call(
            context: @member_ctx, params: { framework_id: @framework_id, capability_id: @cap_id, reason: "x" }
          )
        end
      end
    end
  end
end

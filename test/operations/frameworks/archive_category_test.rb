# frozen_string_literal: true

require "test_helper"

# Archiving a category auto-opens a draft and (once published) marks the
# category archived. A category carries no ratings, so there is no migration
# mapping — but the aggregate refuses to archive one that still holds active
# capabilities, so the category must be emptied first.
class Operations::Frameworks::ArchiveCategoryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @empty_cat = SecureRandom.uuid_v7
      @full_cat = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, @empty_cat, "Empty")
      handler.add_capability_category(@framework_id, @full_cat, "Full")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @full_cat, "Platform Eng")
      handler.publish_version(@framework_id, "seed") # v1; no draft
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "archive an empty category, auto-open a draft, and apply on publish" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ArchiveCategory.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, category_id: @empty_cat, reason: "Retired" }
        )
        assert_equal @empty_cat, result[:category_id]
        assert_equal "Empty", result[:name]

        # Draft auto-opened; the archive is shape-changing — deferred in the
        # published view until publish.
        assert framework.draft_in_progress
        assert_equal "active", FrameworkState::CapabilityCategory.find_by(category_id: @empty_cat).status

        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")
        assert_equal "archived", FrameworkState::CapabilityCategory.find_by(category_id: @empty_cat).status
      end
    end

    should "refuse to archive a category that still holds active capabilities" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(RuntimeError) do
          Operations::Frameworks::ArchiveCategory.call(
            context: @admin_ctx, params: { framework_id: @framework_id, category_id: @full_cat }
          )
        end
        assert_match(/active capability/i, error.message)
      end
    end
  end

  context "archiving a draft-added category" do
    should "resolve it from the graph and archive it" do
      ActsAsTenant.with_tenant(@tenant) do
        new_cat_id = SecureRandom.uuid_v7
        Frameworks::CommandHandler.new.add_capability_category(@framework_id, new_cat_id, "Draft Cat")

        result = Operations::Frameworks::ArchiveCategory.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, category_id: new_cat_id, reason: "oops" }
        )
        assert_equal new_cat_id, result[:category_id]
        assert_nothing_raised { Frameworks::CommandHandler.new.publish_version(@framework_id, "seed") }
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ArchiveCategory.call(
            context: @member_ctx, params: { framework_id: @framework_id, category_id: @empty_cat }
          )
        end
      end
    end
  end
end

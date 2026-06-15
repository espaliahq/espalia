# frozen_string_literal: true

require "test_helper"

# AddCategory adds an (empty) capability category. It is shape-preserving, so
# it applies to the published read model immediately and opens no draft.
class Operations::Frameworks::AddCategoryTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "add the category live without opening a draft" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::AddCategory.call(
          context: @admin_ctx, params: { framework_id: @framework_id, name: "Delivery", ordinal: 2 }
        )

        assert_equal "Delivery", result[:name]
        category = FrameworkState::CapabilityCategory.find_by(
          framework_id: @framework_id, category_id: result[:category_id]
        )
        assert_not_nil category
        assert_equal "Delivery", category.name
        # Shape-preserving — no draft opened.
        assert_not framework.draft_in_progress
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::AddCategory.call(
            context: @member_ctx, params: { framework_id: @framework_id, name: "Nope" }
          )
        end
      end
    end
  end
end

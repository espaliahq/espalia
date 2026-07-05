# frozen_string_literal: true

require "test_helper"

# Category reordering is a direct, shape-preserving structural edit
# (edit-rights bar): the Operation takes the complete ordered id list over the
# ACTIVE categories and refuses anything else as a parameter error.
class Operations::Frameworks::ReorderCategoriesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_a = SecureRandom.uuid_v7
      @cat_b = SecureRandom.uuid_v7
      @cat_c = SecureRandom.uuid_v7
      h = Frameworks::CommandHandler.new
      h.create_framework(@framework_id, "Eng")
      h.add_capability_category(@framework_id, @cat_a, "Thinking")
      h.add_capability_category(@framework_id, @cat_b, "Delivery")
      h.add_capability_category(@framework_id, @cat_c, "Collaboration")
      h.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def ordered_ids
    FrameworkState::CapabilityCategory
      .where(framework_id: @framework_id, status: "active")
      .order(:ordinal, :id).pluck(:category_id)
  end

  context "as tenant admin" do
    should "reorder the categories and renumber ordinals" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ReorderCategories.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, new_ordering: [ @cat_c, @cat_a, @cat_b ] }
        )

        assert_equal [ @cat_c, @cat_a, @cat_b ], result[:new_ordering]
        assert_equal [ @cat_c, @cat_a, @cat_b ], ordered_ids
      end
    end

    should "order the explorer graph by the new ordering" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::ReorderCategories.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, new_ordering: [ @cat_b, @cat_c, @cat_a ] }
        )

        graph = Frameworks::ExplorerGraph.load(@framework_id)
        assert_equal [ @cat_b, @cat_c, @cat_a ], graph.capability_categories.map(&:category_id)
      end
    end

    should "reject an ordering that is not a permutation of the active categories" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::ReorderCategories.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, new_ordering: [ @cat_a, @cat_b ] }
          )
        end
      end
    end
  end

  context "as plain member (no edit rights)" do
    should "deny the reorder" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ReorderCategories.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, new_ordering: [ @cat_c, @cat_a, @cat_b ] }
          )
        end
      end
    end
  end
end

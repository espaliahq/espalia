# frozen_string_literal: true

require "test_helper"

# Capability reordering validates against the ExplorerGraph (not the read
# model) so draft-added capabilities are first-class, and refuses anything
# that isn't an exact permutation of the category's reorderable set.
class Operations::Frameworks::ReorderCapabilitiesTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_person = create(:person, tenant: @tenant, email: @admin_user.email)
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin, person: @admin_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_a = SecureRandom.uuid_v7
      @cap_b = SecureRandom.uuid_v7
      @other_cap = SecureRandom.uuid_v7
      other_cat = SecureRandom.uuid_v7
      h = Frameworks::CommandHandler.new
      h.create_framework(@framework_id, "Eng")
      h.add_capability_category(@framework_id, @cat_id, "Thinking")
      h.add_capability(@framework_id, @cap_a, SecureRandom.uuid_v7, @cat_id, "Strategic Thinking")
      h.add_capability(@framework_id, @cap_b, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      h.add_capability_category(@framework_id, other_cat, "Delivery")
      h.add_capability(@framework_id, @other_cap, SecureRandom.uuid_v7, other_cat, "Shipping")
      h.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: @admin_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def graph_capability_ids
    Frameworks::ExplorerGraph.load(@framework_id)
      .capability_categories.find { |c| c.category_id == @cat_id }
      .capabilities.map(&:capability_id)
  end

  context "as tenant admin" do
    should "reorder the capabilities in graph and read model" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::ReorderCapabilities.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, category_id: @cat_id,
                    new_ordering: [ @cap_b, @cap_a ] }
        )

        assert_equal [ @cap_b, @cap_a ], result[:new_ordering]
        assert_equal [ @cap_b, @cap_a ], graph_capability_ids
        assert_equal 1, FrameworkState::Capability.find_by(capability_id: @cap_b).ordinal
        assert_equal 2, FrameworkState::Capability.find_by(capability_id: @cap_a).ordinal
      end
    end

    should "include a draft-added capability in the reorderable set" do
      ActsAsTenant.with_tenant(@tenant) do
        draft_cap = SecureRandom.uuid_v7
        Frameworks::CommandHandler.new.add_capability(
          @framework_id, draft_cap, SecureRandom.uuid_v7, @cat_id, "Draft-born"
        )

        Operations::Frameworks::ReorderCapabilities.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, category_id: @cat_id,
                    new_ordering: [ draft_cap, @cap_b, @cap_a ] }
        )

        assert_equal [ draft_cap, @cap_b, @cap_a ], graph_capability_ids
        # Draft-added capability has no read-model row yet — skipped, not an error.
        assert_nil FrameworkState::Capability.find_by(capability_id: draft_cap)
      end
    end

    should "reject an ordering that smuggles another category's capability" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::ReorderCapabilities.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, category_id: @cat_id,
                      new_ordering: [ @other_cap, @cap_a ] }
          )
        end
      end
    end
  end

  context "as plain member (no edit rights)" do
    should "deny the reorder" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::ReorderCapabilities.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, category_id: @cat_id,
                      new_ordering: [ @cap_b, @cap_a ] }
          )
        end
      end
    end
  end
end

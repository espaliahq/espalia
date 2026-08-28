# frozen_string_literal: true

require "test_helper"

# AddCapability adds a capability (shape-changing: auto-opens a draft) and
# optionally binds it to roles so it is visible in the role-filtered matrix.
# The add is deferred from the published read model until publish.
class Operations::Frameworks::AddCapabilityTest < ActiveSupport::TestCase
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
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      rfid = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rfid, "Engineering")
      handler.add_role(@framework_id, @role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def add(ctx, params)
    Operations::Frameworks::AddCapability.call(context: ctx, params: params)
  end

  context "as a tenant admin" do
    should "add a bound capability, auto-open a draft, and apply on publish" do
      ActsAsTenant.with_tenant(@tenant) do
        result = add(@admin_ctx, {
          framework_id: @framework_id, category_id: @cat_id, name: "Systems Design", role_ids: [ @role_id ]
        })

        assert_equal [ @role_id ], result[:bound_role_ids]
        assert framework.draft_in_progress
        assert_equal 2, framework.draft_version

        # Shape-changing — deferred from the published read model until publish.
        assert_nil FrameworkState::Capability.find_by(capability_id: result[:capability_id])

        Frameworks::CommandHandler.new.publish_version(@framework_id, "seed")

        cap = FrameworkState::Capability.find_by(capability_id: result[:capability_id])
        assert_not_nil cap
        assert_equal "Systems Design", cap.name
        assert FrameworkState::CapabilityRoleBinding.exists?(
          capability_id: result[:capability_id], role_id: @role_id
        )
      end
    end

    should "reject an unknown role without adding the capability" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add(@admin_ctx, {
            framework_id: @framework_id, category_id: @cat_id, name: "X", role_ids: [ SecureRandom.uuid_v7 ]
          })
        end
        assert_match(/unknown role/i, error.message)
        assert_not framework.draft_in_progress
      end
    end

    should "reject adding a capability with an empty role list" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add(@admin_ctx, {
            framework_id: @framework_id, category_id: @cat_id, name: "Unbound", role_ids: []
          })
        end
        assert_match(/at least one role/i, error.message)
        assert_not framework.draft_in_progress
      end
    end

    should "reject adding a capability with only blank role ids" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add(@admin_ctx, {
            framework_id: @framework_id, category_id: @cat_id, name: "Unbound", role_ids: [ "" ]
          })
        end
        assert_match(/at least one role/i, error.message)
        assert_not framework.draft_in_progress
      end
    end

    should "reject adding a capability with no role_ids at all" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add(@admin_ctx, { framework_id: @framework_id, category_id: @cat_id, name: "Unbound" })
        end
        assert_match(/role_ids/, error.message)
        assert_not framework.draft_in_progress
      end
    end

    should "reject an unknown category" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          add(@admin_ctx, {
            framework_id: @framework_id, category_id: SecureRandom.uuid_v7, name: "X", role_ids: [ @role_id ]
          })
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          add(@member_ctx, {
            framework_id: @framework_id, category_id: @cat_id, name: "X", role_ids: [ @role_id ]
          })
        end
      end
    end
  end
end

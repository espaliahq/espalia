# frozen_string_literal: true

require "test_helper"

# AddRole creates a role inside a role family. Shape-preserving — a role has no
# rating grid until it gains (draft-born) levels — so it applies live and opens
# no draft; the new role is a ghost until publish.
class Operations::Frameworks::AddRoleTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      @framework_id = SecureRandom.uuid_v7
      @rf_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_role_family(@framework_id, @rf_id, "Engineering")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  context "as a tenant admin" do
    should "add the role live without opening a draft" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::AddRole.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_family_id: @rf_id,
                    name: "Engineering Manager", code: "EM", track: "management" }
        )

        role = FrameworkState::Role.find_by(role_family_id: @rf_id, role_id: result[:role_id])
        assert_equal "Engineering Manager", role.name
        assert_equal "EM", role.code
        assert_equal "management", role.track
        assert_empty role.levels
        assert_not framework.draft_in_progress
      end
    end

    should "reject an unknown track as invalid params" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::AddRole.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, role_family_id: @rf_id,
                      name: "X", code: "X", track: "hybrid" }
          )
        end
      end
    end

    should "reject a role family from outside the framework as invalid params" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::AddRole.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, role_family_id: SecureRandom.uuid_v7,
                      name: "X", code: "X", track: "ic" }
          )
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::AddRole.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, role_family_id: @rf_id,
                      name: "Nope", code: "N", track: "ic" }
          )
        end
      end
    end
  end
end

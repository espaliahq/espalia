# frozen_string_literal: true

require "test_helper"

# UpdateRole edits a role's name / code / track. Shape-preserving — applies to
# the published read model immediately and opens no draft.
class Operations::Frameworks::UpdateRoleTest < ActiveSupport::TestCase
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
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_role_family(@framework_id, @rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, @rf_id, "Software Engineer", "E", "ic")
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def role
    FrameworkState::Role.find_by(role_id: @role_id)
  end

  context "as a tenant admin" do
    should "update name / code / track live without opening a draft" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::UpdateRole.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_id: @role_id,
                    name: "Backend Engineer", code: "BE", track: "management" }
        )

        assert_equal "Backend Engineer", result[:name]
        assert_equal "Backend Engineer", role.name
        assert_equal "BE", role.code
        assert_equal "management", role.track
        assert_not framework.draft_in_progress
      end
    end

    should "reject an invalid track at the parameter boundary" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::UpdateRole.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, role_id: @role_id, track: "hybrid" }
          )
        end
      end
    end

    should "raise when no updatable field is supplied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::UpdateRole.call(
            context: @admin_ctx, params: { framework_id: @framework_id, role_id: @role_id }
          )
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::UpdateRole.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, role_id: @role_id, name: "Nope" }
          )
        end
      end
    end
  end
end

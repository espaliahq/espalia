# frozen_string_literal: true

require "test_helper"

# ChangeCollaboratorRole moves a collaborator between FRAMEWORK-WIDE roles —
# the only pairs that share a scope shape, since each scoped lead role has its
# own entity type and the shape is fixed across a change. Scoped roles, a
# supplied scope pair, unheld old roles, already-held new roles, and no-op
# changes all classify as invalid params — never aggregate RuntimeErrors
# (→ internal error over MCP) or duplicate read-model rows.
class Operations::Frameworks::ChangeCollaboratorRoleTest < ActiveSupport::TestCase
  setup do
    @admin_user = create(:user)
    @member_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      @target_person = create(:person, tenant: @tenant)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      handler.add_collaborator(@framework_id, @target_person.id.to_s, "viewer", added_by: nil)
      handler.add_collaborator(@framework_id, @target_person.id.to_s, "capability_lead",
                               scope_type: "capability", scope_id: @cap_id, added_by: nil)
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def change_role(ctx, params)
    Operations::Frameworks::ChangeCollaboratorRole.call(context: ctx, params: params)
  end

  def roles_held
    FrameworkState::Collaborator.for_framework(@framework_id)
      .where(person_id: @target_person.id).pluck(:role).sort
  end

  context "as a tenant admin" do
    should "change a framework-wide role in place" do
      ActsAsTenant.with_tenant(@tenant) do
        result = change_role(@admin_ctx, {
          framework_id: @framework_id, person_id: @target_person.id.to_s,
          old_role: "viewer", new_role: "editor"
        })

        assert result[:changed]
        assert_equal %w[capability_lead editor], roles_held
      end
    end

    # Every scoped lead role has its OWN entity type, so two different scoped
    # roles never share a scope shape — and the shape is fixed across a change.
    # Scoped roles are therefore outside this tool's enum entirely, and the
    # guidance to remove + add lives in its description.
    should "reject a scoped new_role as outside the allowed set" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          change_role(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            old_role: "viewer", new_role: "capability_lead",
            scope_type: "capability", scope_id: @cap_id
          })
        end
        assert_match(/new_role must be one of/, error.message)
        assert_equal %w[capability_lead viewer], roles_held
      end
    end

    should "reject a scoped old_role as outside the allowed set" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          change_role(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            old_role: "capability_lead", new_role: "editor"
          })
        end
        assert_match(/old_role must be one of/, error.message)
        assert_equal %w[capability_lead viewer], roles_held
      end
    end

    # The scope parameters stay declared precisely so a supplied pair is
    # rejected rather than silently dropped by validate_params.
    should "reject a framework-wide change that carries a scope pair" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          change_role(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            old_role: "viewer", new_role: "editor",
            scope_type: "capability", scope_id: @cap_id
          })
        end
        assert_match(/editor is framework-wide/, error.message)
        assert_equal %w[capability_lead viewer], roles_held
      end
    end

    should "reject when the old role is not held" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          change_role(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            old_role: "editor", new_role: "owner"
          })
        end
        assert_match(/does not hold/, error.message)
      end
    end

    should "reject when the new role is already held with the same scope" do
      ActsAsTenant.with_tenant(@tenant) do
        Frameworks::CommandHandler.new.add_collaborator(
          @framework_id, @target_person.id.to_s, "editor", added_by: nil
        )

        error = assert_raises(Operations::Base::ParameterError) do
          change_role(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            old_role: "viewer", new_role: "editor"
          })
        end
        assert_match(/already holds/, error.message)
        # No duplicate editor row was folded into the read model.
        assert_equal %w[capability_lead editor viewer], roles_held
      end
    end

    should "reject a no-op change" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          change_role(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            old_role: "viewer", new_role: "viewer"
          })
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          change_role(@member_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            old_role: "viewer", new_role: "editor"
          })
        end
      end
    end
  end
end

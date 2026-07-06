# frozen_string_literal: true

require "test_helper"

# RemoveCollaborator removes exactly one (person, role, scope) assignment;
# the person's other roles on the framework are untouched (roles are
# additive), and a wrong key classifies as invalid params.
class Operations::Frameworks::RemoveCollaboratorTest < ActiveSupport::TestCase
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
      handler.add_collaborator(@framework_id, @target_person.id.to_s, "editor", added_by: nil)
      handler.add_collaborator(@framework_id, @target_person.id.to_s, "capability_lead",
                               scope_type: "capability", scope_id: @cap_id, added_by: nil)
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def remove_collaborator(ctx, params)
    Operations::Frameworks::RemoveCollaborator.call(context: ctx, params: params)
  end

  def roles_held
    FrameworkState::Collaborator.for_framework(@framework_id)
      .where(person_id: @target_person.id).pluck(:role).sort
  end

  context "as a tenant admin" do
    should "remove a framework-wide role and leave the person's other roles" do
      ActsAsTenant.with_tenant(@tenant) do
        result = remove_collaborator(@admin_ctx, {
          framework_id: @framework_id, person_id: @target_person.id.to_s, role: "editor"
        })

        assert result[:removed]
        assert_equal %w[capability_lead], roles_held
      end
    end

    should "remove a scoped assignment by its exact key" do
      ActsAsTenant.with_tenant(@tenant) do
        remove_collaborator(@admin_ctx, {
          framework_id: @framework_id, person_id: @target_person.id.to_s,
          role: "capability_lead", scope_type: "capability", scope_id: @cap_id
        })

        assert_equal %w[editor], roles_held
      end
    end

    should "reject removing a role the person does not hold" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          remove_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s, role: "owner"
          })
        end
        assert_match(/does not hold/, error.message)
        assert_equal %w[capability_lead editor], roles_held
      end
    end

    should "reject removing a scoped role without its scope key" do
      ActsAsTenant.with_tenant(@tenant) do
        # The assignment is keyed on the full (person, role, scope) tuple —
        # omitting the scope addresses a different (non-existent) assignment.
        assert_raises(Operations::Base::ParameterError) do
          remove_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s, role: "capability_lead"
          })
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          remove_collaborator(@member_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s, role: "editor"
          })
        end
      end
    end
  end
end

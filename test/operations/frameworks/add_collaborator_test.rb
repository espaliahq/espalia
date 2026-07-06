# frozen_string_literal: true

require "test_helper"

# AddCollaborator is the shared web + MCP surface for granting collaborator
# roles: framework-wide roles take no scope, the four lead roles require a
# matching scope pair resolved against the framework, and duplicates /
# unknown people / unknown scope entities classify as client errors rather
# than surfacing aggregate RuntimeErrors.
class Operations::Frameworks::AddCollaboratorTest < ActiveSupport::TestCase
  setup do
    @admin_user = create(:user)
    @owner_user = create(:user)
    @member_user = create(:user)
    @tenant = create(:tenant)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      @owner_tu = create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: @owner_person)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      @target_person = create(:person, tenant: @tenant)

      @framework_id = SecureRandom.uuid_v7
      @cat_id = SecureRandom.uuid_v7
      @cap_id = SecureRandom.uuid_v7
      @family_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng")
      handler.add_capability_category(@framework_id, @cat_id, "Thinking")
      handler.add_capability(@framework_id, @cap_id, SecureRandom.uuid_v7, @cat_id, "Critical Thinking")
      handler.add_role_family(@framework_id, @family_id, "Engineering")
      handler.add_role(@framework_id, @role_id, @family_id, "Software Engineer", "E", "ic")
      handler.add_collaborator(@framework_id, @owner_person.id.to_s, "owner", added_by: @owner_person.id.to_s)
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @owner_ctx = AuthorizationContext.new(user: @owner_user, tenant_user: @owner_tu, person: @owner_person)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def add_collaborator(ctx, params)
    Operations::Frameworks::AddCollaborator.call(context: ctx, params: params)
  end

  def assignments(role)
    FrameworkState::Collaborator.for_framework(@framework_id)
      .where(person_id: @target_person.id, role: role)
  end

  context "as a tenant admin" do
    should "grant a framework-wide role" do
      ActsAsTenant.with_tenant(@tenant) do
        result = add_collaborator(@admin_ctx, {
          framework_id: @framework_id, person_id: @target_person.id.to_s, role: "editor"
        })

        assert result[:added]
        assert_equal "editor", result[:role]
        assert_nil result[:scope_type]
        row = assignments("editor").sole
        assert_nil row.scope_type
        assert_nil row.scope_id
      end
    end

    should "grant a scoped lead role against a framework entity" do
      ActsAsTenant.with_tenant(@tenant) do
        result = add_collaborator(@admin_ctx, {
          framework_id: @framework_id, person_id: @target_person.id.to_s,
          role: "capability_lead", scope_type: "capability", scope_id: @cap_id
        })

        assert result[:added]
        row = assignments("capability_lead").sole
        assert_equal "capability", row.scope_type
        assert_equal @cap_id, row.scope_id
      end
    end

    should "grant a role_lead scoped to a role" do
      ActsAsTenant.with_tenant(@tenant) do
        add_collaborator(@admin_ctx, {
          framework_id: @framework_id, person_id: @target_person.id.to_s,
          role: "role_lead", scope_type: "role", scope_id: @role_id
        })

        assert assignments("role_lead").exists?(scope_id: @role_id)
      end
    end

    should "reject a scoped role without a scope pair" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s, role: "role_lead"
          })
        end
        assert_match(/scoped/, error.message)
        assert_empty assignments("role_lead")
      end
    end

    should "reject a scoped role with the wrong scope_type" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          add_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            role: "capability_lead", scope_type: "role", scope_id: @role_id
          })
        end
      end
    end

    should "reject a framework-wide role carrying a scope" do
      ActsAsTenant.with_tenant(@tenant) do
        error = assert_raises(Operations::Base::ParameterError) do
          add_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            role: "editor", scope_type: "capability", scope_id: @cap_id
          })
        end
        assert_match(/framework-wide/, error.message)
      end
    end

    should "reject an unknown scope entity as not found" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          add_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s,
            role: "capability_lead", scope_type: "capability", scope_id: SecureRandom.uuid_v7
          })
        end
      end
    end

    should "reject an unknown person as not found" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          add_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: SecureRandom.uuid_v7, role: "viewer"
          })
        end
      end
    end

    should "reject a duplicate grant as invalid params" do
      ActsAsTenant.with_tenant(@tenant) do
        add_collaborator(@admin_ctx, {
          framework_id: @framework_id, person_id: @target_person.id.to_s, role: "editor"
        })

        error = assert_raises(Operations::Base::ParameterError) do
          add_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s, role: "editor"
          })
        end
        assert_match(/already holds/, error.message)
        assert_equal 1, assignments("editor").count
      end
    end

    should "reject a role outside the allowed set" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          add_collaborator(@admin_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s, role: "superuser"
          })
        end
      end
    end
  end

  context "as a framework owner without tenant admin" do
    should "be permitted to grant roles" do
      ActsAsTenant.with_tenant(@tenant) do
        result = add_collaborator(@owner_ctx, {
          framework_id: @framework_id, person_id: @target_person.id.to_s, role: "collaborator"
        })

        assert result[:added]
        assert_equal @target_person.id, assignments("collaborator").sole.person_id
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          add_collaborator(@member_ctx, {
            framework_id: @framework_id, person_id: @target_person.id.to_s, role: "viewer"
          })
        end
      end
    end
  end
end

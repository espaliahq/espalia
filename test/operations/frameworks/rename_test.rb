# frozen_string_literal: true

require "test_helper"

# Rename changes a framework's display name. Shape-preserving — applies to the
# published read model and the explorer graph immediately and opens no draft.
class Operations::Frameworks::RenameTest < ActiveSupport::TestCase
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @member_user = create(:user)
    @owner_user = create(:user)
    @editor_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @admin_tu = create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      @member_tu = create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      @owner_person = create(:person, tenant: @tenant, email: @owner_user.email)
      @owner_tu = create(:tenant_user, tenant: @tenant, user: @owner_user, person: @owner_person, role: :member)
      @editor_person = create(:person, tenant: @tenant, email: @editor_user.email)
      @editor_tu = create(:tenant_user, tenant: @tenant, user: @editor_user, person: @editor_person, role: :member)

      @framework_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(@framework_id, "Eng", created_by: @owner_person.id)
      handler.publish_version(@framework_id, "seed")
      create(:framework_collaborator, tenant: @tenant, framework_id: @framework_id,
                                      person_id: @editor_person.id, role: "editor")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
    @owner_ctx = AuthorizationContext.new(user: @owner_user, tenant_user: @owner_tu, person: @owner_person)
    @editor_ctx = AuthorizationContext.new(user: @editor_user, tenant_user: @editor_tu, person: @editor_person)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def rename(ctx, name)
    Operations::Frameworks::Rename.call(context: ctx, params: { framework_id: @framework_id, name: name })
  end

  context "as a tenant admin" do
    should "rename the framework live in the read model AND the graph without opening a draft" do
      ActsAsTenant.with_tenant(@tenant) do
        result = rename(@admin_ctx, "Engineering Career Path")

        assert_equal({ framework_id: @framework_id, name: "Engineering Career Path" }, result)
        assert_equal "Engineering Career Path", framework.name
        assert_equal "Engineering Career Path", Frameworks::ExplorerGraph.load(@framework_id).name
        assert_not framework.draft_in_progress
      end
    end

    should "report the stripped name it actually applied" do
      ActsAsTenant.with_tenant(@tenant) do
        result = rename(@admin_ctx, "  Padded  ")

        assert_equal "Padded", result[:name]
        assert_equal "Padded", framework.name
      end
    end

    should "reject a blank name as a ParameterError" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) { rename(@admin_ctx, "") }
        assert_equal "Eng", framework.name
      end
    end

    should "raise on an unknown framework" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(ActiveRecord::RecordNotFound) do
          Operations::Frameworks::Rename.call(
            context: @admin_ctx, params: { framework_id: SecureRandom.uuid_v7, name: "X" }
          )
        end
      end
    end
  end

  context "as the framework owner (plain tenant member)" do
    should "be permitted" do
      ActsAsTenant.with_tenant(@tenant) do
        rename(@owner_ctx, "Owner Renamed")
        assert_equal "Owner Renamed", framework.name
      end
    end
  end

  context "as an editor collaborator" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) { rename(@editor_ctx, "Nope") }
        assert_equal "Eng", framework.name
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) { rename(@member_ctx, "Nope") }
      end
    end
  end
end

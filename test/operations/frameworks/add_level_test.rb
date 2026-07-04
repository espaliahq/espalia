# frozen_string_literal: true

require "test_helper"

# AddLevel creates a level on a role. Shape-changing — the aggregate auto-opens
# a draft when none is in progress, and the level is deferred from the
# published read model until publish (ADR-16).
class Operations::Frameworks::AddLevelTest < ActiveSupport::TestCase
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
      handler.add_level(@framework_id, SecureRandom.uuid_v7, @role_id, 1, "Engineer I", "E1", is_entry: true)
      handler.publish_version(@framework_id, "seed")
    end

    @admin_ctx = AuthorizationContext.new(user: @admin_user, tenant_user: @admin_tu, person: nil)
    @member_ctx = AuthorizationContext.new(user: @member_user, tenant_user: @member_tu, person: nil)
  end

  def framework
    FrameworkState::Framework.find_by!(framework_id: @framework_id)
  end

  def graph_levels
    graph = Frameworks::ExplorerGraph.load(@framework_id)
    graph.role_families.flat_map(&:roles).find { |r| r.role_id == @role_id }.levels
  end

  context "as a tenant admin" do
    should "add the level into an auto-opened draft, deferred from the published read model" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::AddLevel.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_id: @role_id,
                    ordinal: 2, title: "Engineer II", code: "E2" }
        )

        assert framework.reload.draft_in_progress, "shape-changing add must open a draft"
        # Deferred from the published read model until publish (ADR-16)…
        assert_nil FrameworkState::Level.find_by(level_id: result[:level_id])
        # …but present in the graph (edit-mode source), flagged as draft-added.
        level = graph_levels.find { |l| l.level_id == result[:level_id] }
        assert level
        assert level.added_in_draft
        assert_equal 2, level.ordinal
        assert_not level.is_entry
      end
    end

    should "cast a web-form is_entry string" do
      ActsAsTenant.with_tenant(@tenant) do
        result = Operations::Frameworks::AddLevel.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_id: @role_id,
                    ordinal: 3, title: "Engineer III", code: "E3", is_entry: "1" }
        )
        assert graph_levels.find { |l| l.level_id == result[:level_id] }.is_entry
      end
    end

    should "reject a duplicate ordinal on the same role (draft levels included)" do
      ActsAsTenant.with_tenant(@tenant) do
        Operations::Frameworks::AddLevel.call(
          context: @admin_ctx,
          params: { framework_id: @framework_id, role_id: @role_id, ordinal: 2, title: "A", code: "A2" }
        )
        # The first add is draft-only (not in the read model) — the guard must
        # still see it.
        err = assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::AddLevel.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, role_id: @role_id, ordinal: 2, title: "B", code: "B2" }
          )
        end
        assert_match(/already has a level at ordinal 2/, err.message)
      end
    end

    should "reject a non-positive ordinal" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::AddLevel.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, role_id: @role_id, ordinal: -1, title: "X", code: "X" }
          )
        end
      end
    end

    should "reject a role from outside the framework as invalid params" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Operations::Base::ParameterError) do
          Operations::Frameworks::AddLevel.call(
            context: @admin_ctx,
            params: { framework_id: @framework_id, role_id: SecureRandom.uuid_v7,
                      ordinal: 2, title: "X", code: "X" }
          )
        end
      end
    end
  end

  context "as a plain tenant member" do
    should "be denied" do
      ActsAsTenant.with_tenant(@tenant) do
        assert_raises(Pundit::NotAuthorizedError) do
          Operations::Frameworks::AddLevel.call(
            context: @member_ctx,
            params: { framework_id: @framework_id, role_id: @role_id,
                      ordinal: 2, title: "Nope", code: "N2" }
          )
        end
      end
    end
  end
end

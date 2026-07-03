# frozen_string_literal: true

require "test_helper"

# Unit coverage for the ghost-entity predicates — "not visible in the published
# framework view yet" derived from published-level presence, against both
# substrates the tree renders (ExplorerGraph Data nodes and AR read models).
class Views::Frameworks::Explorer::GhostEntitiesTest < ActiveSupport::TestCase
  class Host
    include Views::Frameworks::Explorer::Concerns::GhostEntities
  end

  setup { @g = Host.new }

  def graph_level(added_in_draft:)
    Frameworks::ExplorerGraph::Level.new(
      level_id: SecureRandom.uuid_v7, role_id: "r1", ordinal: 1,
      title: "Engineer I", code: "E1", is_entry: true, added_in_draft: added_in_draft
    )
  end

  def graph_role(levels:)
    Frameworks::ExplorerGraph::Role.new(
      role_id: "r1", role_family_id: "rf1", name: "Software Engineer",
      code: "E", track: "ic", levels: levels
    )
  end

  def graph_family(roles:)
    Frameworks::ExplorerGraph::RoleFamily.new(
      role_family_id: "rf1", name: "Engineering", description: nil,
      department: nil, roles: roles
    )
  end

  context "#ghost_role? (graph nodes)" do
    should "flag a role with no levels" do
      assert @g.ghost_role?(graph_role(levels: []))
    end

    should "flag a role whose levels are all still in the draft" do
      assert @g.ghost_role?(graph_role(levels: [ graph_level(added_in_draft: true) ]))
    end

    should "not flag a role with at least one published level" do
      role = graph_role(levels: [ graph_level(added_in_draft: true), graph_level(added_in_draft: false) ])
      assert_not @g.ghost_role?(role)
    end
  end

  context "#ghost_role? (AR read models — published levels by construction)" do
    should "flag a level-less role and clear once a level row exists" do
      tenant = FactoryBot.create(:tenant)
      ActsAsTenant.with_tenant(tenant) do
        family = FactoryBot.create(:framework_role_family, tenant: tenant)
        role = FactoryBot.create(:framework_role, tenant: tenant, role_family_id: family.role_family_id)

        assert @g.ghost_role?(role)

        FactoryBot.create(:framework_level, tenant: tenant, role_id: role.role_id)
        assert_not @g.ghost_role?(role.reload)
      end
    end
  end

  context "#ghost_role_family?" do
    should "flag a family with no roles" do
      assert @g.ghost_role_family?(graph_family(roles: []))
    end

    should "flag a family whose roles are all ghosts" do
      assert @g.ghost_role_family?(graph_family(roles: [ graph_role(levels: []) ]))
    end

    should "not flag a family with a published role" do
      family = graph_family(roles: [ graph_role(levels: [ graph_level(added_in_draft: false) ]) ])
      assert_not @g.ghost_role_family?(family)
    end
  end
end

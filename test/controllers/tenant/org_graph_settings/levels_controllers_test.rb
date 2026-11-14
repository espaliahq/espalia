# frozen_string_literal: true

require "test_helper"

class Tenant::OrgGraphSettings::LevelsControllersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user)
    @editor_user = create(:user)
    @tribe_id = SecureRandom.uuid_v7
    @squad_id = SecureRandom.uuid_v7
    @team_id = SecureRandom.uuid_v7
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @editor_user, role: :member, org_graph_editor: true)
      structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
      structure.define_taxonomy([ { level_id: @tribe_id, name: "Tribe" }, { level_id: @squad_id, name: "Squad" },
                                  { level_id: @team_id, name: "Team" } ], effective_on: Date.current)
      tribe = SecureRandom.uuid_v7
      structure.create_unit(tribe, "Commerce", level_id: @tribe_id, effective_on: Date.current)
      structure.create_unit(SecureRandom.uuid_v7, "Payments", level_id: @team_id, parent_id: tribe, effective_on: Date.current)
    end
  end

  def level_names = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_first.pluck(:name) }

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "add a level at the bottom" do
      post tenant_org_graph_settings_levels_path, params: { name: " Guild " }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Guild is now the bottom level. Move it up if it belongs higher.", flash[:notice]
      assert_equal %w[Tribe Squad Team Guild], level_names
    end

    should "say why a level could not be added" do
      post tenant_org_graph_settings_levels_path, params: { name: "squad" }

      assert_equal "The level could not be added: There is already a level called Squad", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names
    end

    should "ask for a name" do
      post tenant_org_graph_settings_levels_path, params: { name: " " }

      assert_equal "The level could not be added: name can't be blank", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names
    end

    should "move an empty level past one that holds units" do
      patch tenant_org_graph_settings_level_order_path,
            params: { level_id: @squad_id, direction: "down" }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Squad moved down.", flash[:notice]
      assert_equal %w[Tribe Team Squad], level_names
    end

    should "say why two levels that both hold units keep their order" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .reorder_levels([ @tribe_id, @team_id, @squad_id ], effective_on: Date.current)
      end

      patch tenant_org_graph_settings_level_order_path, params: { level_id: @team_id, direction: "up" }

      assert_equal "Team did not move: Tribe and Team both hold units, so Tribe must stay above Team", flash[:alert]
      assert_equal %w[Tribe Team Squad], level_names
    end

    should "move from the order as it stands, not the order the page showed" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .reorder_levels([ @tribe_id, @team_id, @squad_id ], effective_on: Date.current)
      end

      patch tenant_org_graph_settings_level_order_path, params: { level_id: @squad_id, direction: "up" }

      assert_equal "Squad moved up.", flash[:notice]
      assert_equal %w[Tribe Squad Team], level_names
    end

    should "say a level at the bottom can't move down" do
      patch tenant_org_graph_settings_level_order_path, params: { level_id: @team_id, direction: "down" }

      assert_equal "Team did not move: it is already at the bottom.", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names
    end

    should "refuse a move without a level" do
      patch tenant_org_graph_settings_level_order_path, params: { direction: "up" }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "That level no longer exists.", flash[:alert]
    end

    should "offer only the moves the levels allow" do
      get tenant_org_graph_settings_path

      assert_select "#org-graph-level-up-#{@tribe_id}", count: 0
      assert_select "#org-graph-level-down-#{@tribe_id}"
      assert_select "#org-graph-level-up-#{@squad_id}"
      assert_select "#org-graph-level-down-#{@squad_id}"
      assert_select "#org-graph-level-up-#{@team_id}"
      assert_select "#org-graph-level-down-#{@team_id}", count: 0
      assert_select "#org-graph-levels input#org-graph-new-level[name=name]"
    end

    should "remove a level no unit has ever held" do
      delete tenant_org_graph_settings_level_path(@squad_id)

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Squad is no longer a level.", flash[:notice]
      assert_equal %w[Tribe Team], level_names
    end

    should "name the units that keep a level in place" do
      delete tenant_org_graph_settings_level_path(@team_id)

      assert_equal "The level could not be removed: Team can't be removed, as it holds Payments", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names
    end

    should "refuse a level an HRIS provides, and one that is already gone" do
      region_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).define_taxonomy(
          [ { level_id: region_id, name: "Region", provider: "hibob" }, { level_id: @tribe_id, name: "Tribe" },
            { level_id: @squad_id, name: "Squad" }, { level_id: @team_id, name: "Team" } ], effective_on: Date.current
        )
      end

      delete tenant_org_graph_settings_level_path(region_id)
      assert_equal "The level could not be removed: Region comes from HiBob; hand it back to Espalia before removing it",
                   flash[:alert]

      delete tenant_org_graph_settings_level_path(SecureRandom.uuid_v7)
      assert_equal "The level could not be removed: Level is not in the taxonomy", flash[:alert]
      assert_equal %w[Region Tribe Squad Team], level_names
    end

    should "offer Remove only on a level no unit has ever held, and name the retired units of one that did" do
      ActsAsTenant.with_tenant(@tenant) do
        structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        @guild_id = SecureRandom.uuid_v7
        structure.add_level(@guild_id, "Guild", effective_on: Date.current)
        unit_id = SecureRandom.uuid_v7
        structure.create_unit(unit_id, "Atlas", level_id: @guild_id, effective_on: Date.current)
        structure.retire_unit(unit_id, effective_on: Date.current)
      end

      get tenant_org_graph_settings_path

      assert_select "#org-graph-level-remove-#{@squad_id}", text: "Remove"
      assert_select "#org-graph-level-remove-#{@team_id}", count: 0
      assert_select "#org-graph-level-remove-#{@guild_id}", count: 0
      assert_select "#org-graph-level-#{@guild_id}", text: /held Atlas/
    end
  end

  context "as an Org Graph editor" do
    setup { sign_in @editor_user }

    should "refuse to add, move or remove a level, and offer none of them" do
      post tenant_org_graph_settings_levels_path, params: { name: "Guild" }
      assert_equal "You are not authorized to perform this action.", flash[:alert]

      patch tenant_org_graph_settings_level_order_path,
            params: { level_id: @squad_id, direction: "down" }
      assert_equal "You are not authorized to perform this action.", flash[:alert]

      delete tenant_org_graph_settings_level_path(@squad_id)
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names

      get tenant_org_graph_settings_path
      assert_select "#org-graph-level-remove-#{@squad_id}", count: 0
    end
  end
end

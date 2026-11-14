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
            params: { level_ids: [ @tribe_id, @team_id, @squad_id ], level_id: @squad_id, direction: "down" }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Squad moved down.", flash[:notice]
      assert_equal %w[Tribe Team Squad], level_names
    end

    should "say why two levels that both hold units keep their order" do
      patch tenant_org_graph_settings_level_order_path,
            params: { level_ids: [ @squad_id, @team_id, @tribe_id ], level_id: @tribe_id, direction: "down" }

      assert_equal "Tribe did not move: Tribe and Team both hold units, so Tribe must stay above Team", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names
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
  end

  context "as an Org Graph editor" do
    setup { sign_in @editor_user }

    should "refuse to add or move a level" do
      post tenant_org_graph_settings_levels_path, params: { name: "Guild" }
      assert_equal "You are not authorized to perform this action.", flash[:alert]

      patch tenant_org_graph_settings_level_order_path,
            params: { level_ids: [ @tribe_id, @team_id, @squad_id ], level_id: @squad_id, direction: "down" }
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names
    end
  end
end

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
      @commerce_id = SecureRandom.uuid_v7
      structure.create_unit(@commerce_id, "Commerce", level_id: @tribe_id, effective_on: Date.current)
      @payments_id = SecureRandom.uuid_v7
      structure.create_unit(@payments_id, "Payments", level_id: @team_id, parent_id: @commerce_id, effective_on: Date.current)
    end
  end

  def own_names = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.in_structure(@payments_id).pluck(:name) }

  def level_names = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_structure.pluck(:name) }

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "add a level at the bottom" do
      post tenant_org_graph_settings_levels_path, params: { name: " Guild " }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Guild is a unit type now. It can sit under any other type, or at the top, until you narrow that.", flash[:notice]
      assert_equal %w[Tribe Squad Team Guild], level_names
    end

    should "say why a level could not be added" do
      post tenant_org_graph_settings_levels_path, params: { name: "squad" }

      assert_equal "The unit type could not be added: There is already a unit type called Squad", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names
    end

    should "send a unit with no structure of its own back to the Units view" do
      get edit_tenant_org_structure_path(@payments_id)

      assert_redirected_to tenant_org_graph_path(unit: @payments_id)
      assert_equal "Payments has no structure of its own to change.", flash[:alert]
    end

    should "find no structure page for a unit the Org Graph doesn't hold" do
      get edit_tenant_org_structure_path(SecureRandom.uuid)

      assert_response :not_found
    end

    should "ask for a name" do
      post tenant_org_graph_settings_levels_path, params: { name: " " }

      assert_equal "The unit type could not be added: name can't be blank", flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names
    end

    should "save the types a unit type can sit under, and whether it can sit at the top" do
      patch tenant_org_graph_settings_kind_parent_path(@squad_id), params: { parent_ids: [ @tribe_id, @squad_id ], top: "0" }

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Saved where Squad can sit.", flash[:notice]
      squad = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.taxonomy.kind(@squad_id) }
      assert_equal [ [ @squad_id, @tribe_id ].sort, false ], [ squad.parent_ids.sort, squad.top? ]
    end

    should "save over the rules the page drew, and refuse a page drawn before another admin's change" do
      drawn = { was_parent_ids: [ @tribe_id ], was_top: "1" }
      patch tenant_org_graph_settings_kind_parent_path(@squad_id), params: { parent_ids: [ @tribe_id ], top: "0", **drawn }
      assert_equal "Saved where Squad can sit.", flash[:notice]

      patch tenant_org_graph_settings_kind_parent_path(@squad_id), params: { parent_ids: [ @tribe_id ], top: "1", **drawn }

      assert_equal "Someone changed where Squad can sit while this page was open, so yours wasn't saved. " \
                   "The boxes now show their change: tick yours again and save.", flash[:alert]
      assert_not ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.taxonomy.kind(@squad_id).top? }
    end

    should "name the units a narrower list would leave where they no longer fit" do
      patch tenant_org_graph_settings_kind_parent_path(@team_id), params: { parent_ids: [ @squad_id ], top: "1" }

      assert_match(/\ATeam's place did not change: These units wouldn't fit this structure, so move them first: Payments/,
                   flash[:alert])
      team = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.taxonomy.kind(@team_id) }
      assert_equal [ @tribe_id, @squad_id ], team.parent_ids
    end

    should "refuse a unit type with nowhere to sit, as unticking every box sends no list" do
      patch tenant_org_graph_settings_kind_parent_path(@squad_id), params: { top: "0" }

      assert_equal "Squad's place did not change: A unit type needs somewhere to sit: under another type, or at the top",
                   flash[:alert]
    end

    should "offer each unit type a box per type and the top switch, ticked as its rules stand, and no reordering" do
      get tenant_org_graph_settings_path

      assert_select "#org-graph-levels h2", text: "Unit types"
      assert_select "form#org-graph-level-rules-#{@team_id}" do
        assert_select "legend", text: "Can sit under"
        assert_select "input[type=checkbox][name='parent_ids[]']", count: 3
        assert_select "input[type=checkbox][name='parent_ids[]'][checked]", count: 2
        assert_select "input#org-graph-level-#{@team_id}-under-#{@tribe_id}[checked]"
        assert_select "input#org-graph-level-#{@team_id}-under-#{@squad_id}[checked]"
        assert_select "label[for=?]", "org-graph-level-#{@team_id}-under-#{@team_id}", text: "Team (inside another Team)"
        assert_select "input#org-graph-level-top-#{@team_id}[checked]"
        assert_select "input[type=hidden][name=was_top][value='1']"
      end
      drawn = css_select("form#org-graph-level-rules-#{@team_id} input[type=hidden][name='was_parent_ids[]']")
      assert_equal [ @tribe_id, @squad_id ], drawn.map { it["value"] }
      assert_select "[id^='org-graph-level-up-'], [id^='org-graph-level-down-']", count: 0
      assert_select "#org-graph-levels input#org-graph-new-level[name=name]"
    end

    should "offer an HRIS type the same boxes, and refuse a rule an HRIS type can't keep" do
      region_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM).define_taxonomy(
          [ { level_id: region_id, name: "Region", provider: "hibob" }, { level_id: @tribe_id, name: "Tribe" },
            { level_id: @squad_id, name: "Squad" }, { level_id: @team_id, name: "Team" } ], effective_on: Date.current
        )
      end

      get tenant_org_graph_settings_path
      assert_select "form#org-graph-level-rules-#{region_id} input#org-graph-level-top-#{region_id}[checked]"
      assert_select "#org-graph-level-#{region_id}", text: /Comes from HiBob · 0 units/

      patch tenant_org_graph_settings_kind_parent_path(region_id), params: { parent_ids: [ @tribe_id ], top: "0" }

      assert_equal "Region's place did not change: Region can sit only at the top, or under one type above it " \
                   "that an HRIS provides, while it comes from HiBob", flash[:alert]
      assert ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.taxonomy.kind(region_id).top? }
    end

    should "remove a level no unit has ever held" do
      delete tenant_org_graph_settings_level_path(@squad_id)

      assert_redirected_to tenant_org_graph_settings_path
      assert_equal "Squad is no longer a unit type.", flash[:notice]
      assert_equal %w[Tribe Team], level_names
    end

    should "name the units that keep a level in place" do
      delete tenant_org_graph_settings_level_path(@team_id)

      assert_equal "The unit type could not be removed: Team can't be removed, as it holds Payments", flash[:alert]
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
      assert_equal "The unit type could not be removed: Region comes from HiBob; hand it back to Espalia before removing it",
                   flash[:alert]

      delete tenant_org_graph_settings_level_path(SecureRandom.uuid_v7)
      assert_equal "The unit type could not be removed: That unit type doesn't exist", flash[:alert]
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

      assert_select "#org-graph-level-remove-#{@squad_id}", text: "Remove Squad"
      assert_select "#org-graph-level-remove-#{@team_id}", count: 0
      assert_select "#org-graph-level-remove-#{@guild_id}", count: 0
      assert_select "#org-graph-level-#{@guild_id}", text: /0 units · held Atlas/
      assert_select "#org-graph-level-#{@team_id}", text: /Managed here · holds Payments/
      assert_select "#org-graph-level-menu-#{@squad_id}[aria-label=?]", "Actions for Squad"
    end
  end

  context "as a tenant admin, with Payments' own structure" do
    setup do
      @pod_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        tenant_user = TenantUser.find_by!(user: @admin_user)
        admin = AuthorizationContext.new(user: @admin_user, tenant_user:, person: nil)
        OrgGraph::StructureCommandHandler.new(actor: admin).declare_structure(
          @payments_id, levels: [ { level_id: @pod_id, name: "Pod", parent_level_ids: [ @pod_id ], top: true } ],
                        conversion: {}, effective_on: Date.current
        )
      end
      sign_in @admin_user
    end

    should "show Payments' types in a panel of their own, whose forms name Payments and which has no HRIS pickers" do
      get tenant_org_graph_settings_path

      assert_select "#org-graph-levels-#{@payments_id}" do
        assert_select "h2", text: "Unit types beneath Payments"
        assert_select "#org-graph-level-#{@pod_id}", text: /Managed here · 0 units/
        assert_select "form#org-graph-level-rules-#{@pod_id} input[type=hidden][name=structure_unit_id][value=?]", @payments_id
        assert_select "label", text: "Can sit directly under Payments"
        assert_select "input#org-graph-new-level-#{@payments_id}[name=name]"
        assert_select "turbo-frame", count: 0
      end
      assert_select "#org-graph-levels h2", text: "Unit types"
      assert_select "#org-graph-levels #org-graph-level-#{@pod_id}", count: 0
    end

    should "add, rule and remove a type in Payments' structure, landing back on its panel" do
      post tenant_org_graph_settings_levels_path, params: { name: "Guild", structure_unit_id: @payments_id }
      assert_equal "Guild is a unit type now. It can sit under any other type, or directly under Payments, until you narrow that.",
                   flash[:notice]
      assert_redirected_to tenant_org_graph_settings_path(anchor: "org-graph-levels-#{@payments_id}")
      assert_equal %w[Pod Guild], own_names
      assert_equal %w[Tribe Squad Team], level_names

      guild_id = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.in_structure(@payments_id).find_by!(name: "Guild").id }
      drawn = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.rules_by_id(OrgTaxonomyLevel.in_structure(@payments_id).to_a) }
                          .fetch(guild_id)
      patch tenant_org_graph_settings_kind_parent_path(guild_id),
            params: { parent_ids: [ @pod_id ], top: "0", was_parent_ids: drawn[:parent_ids], was_top: drawn[:top] ? "1" : "0",
                      structure_unit_id: @payments_id }
      assert_equal [ "Saved where Guild can sit.", nil ], [ flash[:notice], flash[:alert] ]
      assert_redirected_to tenant_org_graph_settings_path(anchor: "org-graph-levels-#{@payments_id}")

      delete tenant_org_graph_settings_level_path(guild_id), params: { structure_unit_id: @payments_id }
      assert_equal "Guild is no longer a unit type.", flash[:notice]
      assert_equal %w[Pod], own_names
    end
  end

  context "as Payments' owner, with Payments' own structure" do
    setup do
      @pod_id = SecureRandom.uuid_v7
      @owner_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        owner = create(:person, tenant: @tenant)
        create(:tenant_user, tenant: @tenant, user: @owner_user, role: :member, person: owner)
        structure = OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
        structure.add_unit_owner(@payments_id, owner.id, effective_on: Date.current)
        admin = AuthorizationContext.new(user: @admin_user, tenant_user: TenantUser.find_by!(user: @admin_user), person: nil)
        OrgGraph::StructureCommandHandler.new(actor: admin).declare_structure(
          @payments_id, levels: [ { level_id: @pod_id, name: "Pod", parent_level_ids: [ @pod_id ], top: true } ],
                        conversion: {}, effective_on: Date.current
        )
      end
      sign_in @owner_user
    end

    should "add, rule and remove a type in Payments' structure" do
      post tenant_org_graph_settings_levels_path, params: { name: "Guild", structure_unit_id: @payments_id }
      assert_nil flash[:alert]
      assert_equal %w[Pod Guild], own_names

      guild_id = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.in_structure(@payments_id).find_by!(name: "Guild").id }
      patch tenant_org_graph_settings_kind_parent_path(guild_id),
            params: { parent_ids: [ @pod_id ], top: "0", structure_unit_id: @payments_id }
      assert_equal [ "Saved where Guild can sit.", nil ], [ flash[:notice], flash[:alert] ]

      delete tenant_org_graph_settings_level_path(guild_id), params: { structure_unit_id: @payments_id }
      assert_nil flash[:alert]
      assert_equal %w[Pod], own_names
    end

    should "open Payments' structure on a page of its own, in the app's layout, and land its writes back there" do
      get edit_tenant_org_structure_path(@payments_id)

      assert_response :success
      assert_select "h1", text: "The structure beneath Payments"
      assert_select "a[href='#{tenant_org_graph_path}']", text: "Organisation"
      assert_select "a[href='#{tenant_org_graph_settings_path}']", count: 0
      assert_select "#org-graph-levels-#{@payments_id} input[name='back'][value='structure']"

      post tenant_org_graph_settings_levels_path, params: { name: "Guild", structure_unit_id: @payments_id, back: "structure" }
      assert_redirected_to edit_tenant_org_structure_path(@payments_id)
      assert_equal %w[Pod Guild], own_names

      post tenant_org_graph_settings_levels_path, params: { name: "pod", structure_unit_id: @payments_id, back: "structure" }
      assert_redirected_to edit_tenant_org_structure_path(@payments_id)
      assert_predicate flash[:alert], :present?
    end

    should "land a refusal from the write back on the structure page, naming it" do
      refusal = OrgGraph::Authorization::Refused.new("You can't change the structure beneath Payments.")
      Operations::OrgGraph::AddLevel.stub(:call, ->(**) { raise refusal }) do
        post tenant_org_graph_settings_levels_path, params: { name: "Guild", structure_unit_id: @payments_id, back: "structure" }
      end

      assert_redirected_to edit_tenant_org_structure_path(@payments_id)
      assert_equal "The unit type could not be added: You can't change the structure beneath Payments.", flash[:alert]
    end

    should "land a write on the unit, not the structure page, once Payments has no structure left" do
      ActsAsTenant.with_tenant(@tenant) do
        admin = AuthorizationContext.new(user: @admin_user, tenant_user: TenantUser.find_by!(user: @admin_user), person: nil)
        OrgGraph::StructureCommandHandler.new(actor: admin).withdraw_structure(@payments_id, conversion: {}, effective_on: Date.current)
      end

      delete tenant_org_graph_settings_level_path(@pod_id), params: { structure_unit_id: @payments_id, back: "structure" }

      assert_redirected_to tenant_org_graph_path(unit: @payments_id)
    end

    should "not open the structure page of a unit they don't own" do
      get edit_tenant_org_structure_path(@commerce_id)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "refuse a type from the organisation's or another unit's structure, named under Payments, writing nothing" do
      lane_id = SecureRandom.uuid_v7
      ActsAsTenant.with_tenant(@tenant) do
        identity_id = SecureRandom.uuid_v7
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .create_unit(identity_id, "Identity", level_id: @tribe_id, effective_on: Date.current)
        admin = AuthorizationContext.new(user: @admin_user, tenant_user: TenantUser.find_by!(user: @admin_user), person: nil)
        OrgGraph::StructureCommandHandler.new(actor: admin).declare_structure(
          identity_id, levels: [ { level_id: lane_id, name: "Lane", parent_level_ids: [ lane_id ], top: true } ],
                        conversion: {}, effective_on: Date.current
        )
      end
      events = Rails.configuration.event_store.read.count
      under_payments = { structure_unit_id: @payments_id }

      [ @squad_id, lane_id ].each do |foreign|
        [ -> { patch tenant_org_graph_settings_kind_parent_path(foreign), params: { parent_ids: [], top: "1", **under_payments } },
          -> { patch tenant_org_graph_settings_kind_parent_path(@pod_id), params: { parent_ids: [ foreign ], top: "0", **under_payments } },
          -> { delete tenant_org_graph_settings_level_path(foreign), params: under_payments } ].each do |request|
          request.call
          assert_match(/doesn't exist|this structure doesn't hold/, flash[:alert])
          assert_nil flash[:notice]
        end
      end
      assert_equal events, Rails.configuration.event_store.read.count
      assert_equal %w[Tribe Squad Team], level_names
      assert_equal %w[Pod], own_names
    end

    should "refuse to change the organisation's structure" do
      [ -> { post tenant_org_graph_settings_levels_path, params: { name: "Guild" } },
        -> { patch tenant_org_graph_settings_kind_parent_path(@squad_id), params: { parent_ids: [], top: "1" } },
        -> { delete tenant_org_graph_settings_level_path(@team_id) } ].each do |request|
        request.call
        assert_equal "You are not authorized to perform this action.", flash[:alert]
      end
      assert_equal %w[Tribe Squad Team], level_names
    end
  end

  context "as a member with no rights" do
    setup do
      @member_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: @member_user, role: :member, person: create(:person, tenant: @tenant))
      end
      sign_in @member_user
    end

    should "refuse to add, rule or remove a unit type, in either structure, changing nothing" do
      [ {}, { structure_unit_id: @payments_id } ].each do |structure|
        [ -> { post tenant_org_graph_settings_levels_path, params: { name: "Guild", **structure } },
          -> { patch tenant_org_graph_settings_kind_parent_path(@squad_id), params: { parent_ids: [], top: "1", **structure } },
          -> { delete tenant_org_graph_settings_level_path(@team_id), params: structure } ].each do |request|
          request.call
          assert_redirected_to root_path
          assert_equal "You are not authorized to perform this action.", flash[:alert]
        end
      end
      assert_equal %w[Tribe Squad Team], level_names
      assert_empty own_names
    end
  end

  context "as an Org Graph editor" do
    setup { sign_in @editor_user }

    should "add, change and remove a unit type, as the MCP tools let them, though Settings stays the admin's" do
      post tenant_org_graph_settings_levels_path, params: { name: "Guild" }
      assert_nil flash[:alert]
      assert_equal %w[Tribe Squad Team Guild], level_names

      guild_id = ActsAsTenant.with_tenant(@tenant) { OrgTaxonomyLevel.top_structure.find_by!(name: "Guild").id }
      delete tenant_org_graph_settings_level_path(guild_id)
      assert_nil flash[:alert]
      assert_equal %w[Tribe Squad Team], level_names

      get tenant_org_graph_settings_path
      assert_select "#org-graph-level-menu-#{@squad_id}", count: 0
    end
  end
end

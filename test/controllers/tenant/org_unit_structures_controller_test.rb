# frozen_string_literal: true

require "test_helper"

# A unit's own structure from its drawer (#494): giving it one, withdrawing
# it, and moving a unit into one. OrgUnitStructureDeclarationsController,
# OrgUnitStructureWithdrawalsController and OrgUnitStructureMovesController.
class Tenant::OrgUnitStructuresControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @admin_user = create(:user)
    @member_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
    end
    sign_in @admin_user
  end

  def drawer = Nokogiri::HTML5(response.body).at_css("aside#org-graph-drawer")

  def overview = ActsAsTenant.with_tenant(@tenant) { OrgGraph::UnitsOverview.new }

  def type_of(key) = overview.then { it.level_of(it.unit(@org[key])).name }

  def own_types(key) = overview.structures.fetch(@org[key], []).map(&:name)

  def declare_fresh(key, names)
    post tenant_org_unit_structure_declaration_path(@org[key]), params: { start: "fresh", names: }
  end

  should "say which structure is in force in the drawer, and offer an admin their own" do
    get edit_tenant_org_unit_path(@org[:checkout])

    section = drawer.at_css("#org-unit-structure")
    assert_includes section.text, "Its unit type comes from the organisation's structure."
    assert section.at_css("a[aria-label='Give Checkout its own structure']")
  end

  should "give a unit a copy of the structure in force, each type beneath it taking its copy" do
    get new_tenant_org_unit_structure_declaration_path(@org[:checkout])
    assert_includes drawer.at_css("#org-unit-structure-copy").text, "It starts with the types in the organisation's structure"
    assert_includes drawer.at_css("#org-unit-structure-copy").text, "Department, Team, and Squad"
    assert_match(/\A\d+ units? changes? type\.\z/, drawer.at_css("#org-unit-structure-count").text)
    assert_equal "Squad", drawer.at_css("select[name='conversion[#{@org[:squad]}]'] option[selected]").text

    post tenant_org_unit_structure_declaration_path(@org[:checkout]), params: { start: "copy", conversion: { @org[:squad] => @org[:squad] } }

    assert_redirected_to tenant_org_graph_settings_path(anchor: "org-graph-levels-#{@org[:checkout]}")
    assert_equal %w[Department Team Squad], own_types(:checkout)
    assert_equal "Squad", type_of(:payments)
    assert_not_equal @org[:squad], overview.unit(@org[:payments]).level_id
    assert_equal "Team", type_of(:checkout)
  end

  should "give a unit a copy in which the types its own units hold can sit directly beneath it" do
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .set_kind_parents(@org[:squad], parent_ids: [ @org[:team] ], top: false, effective_on: Date.current)
    end

    post tenant_org_unit_structure_declaration_path(@org[:checkout]), params: { start: "copy", conversion: { @org[:squad] => @org[:squad] } }

    assert_redirected_to tenant_org_graph_settings_path(anchor: "org-graph-levels-#{@org[:checkout]}")
    assert_equal %w[Department Team Squad], own_types(:checkout)
    assert_equal "Squad", type_of(:payments)
  end

  should "give a unit new types, each able to sit anywhere in it, and then say so in its drawer" do
    get new_tenant_org_unit_structure_declaration_path(@org[:checkout], fresh: 1)
    assert_equal "Every type can sit anywhere in it for now. Tighten that in Settings.",
                 drawer.at_css("#org-unit-structure-permissive").text

    declare_fresh(:checkout, { @org[:squad] => "Group" })

    assert_equal [ "Group" ], own_types(:checkout)
    assert_equal "Group", type_of(:payments)
    group = overview.structures.fetch(@org[:checkout]).first
    assert group.top
    assert_equal [ group.id ], group.parent_level_ids

    get edit_tenant_org_unit_path(@org[:checkout])
    assert_includes drawer.at_css("#org-unit-own-structure").text, "Checkout has its own structure, which the units beneath it use: Group."
    assert drawer.at_css("a[aria-label=\"Withdraw Checkout's structure\"]")
  end

  should "come back to the step with the reason when the declaration is refused" do
    declare_fresh(:checkout, { @org[:squad] => "" })

    assert_redirected_to new_tenant_org_unit_structure_declaration_path(@org[:checkout], fresh: 1)
    assert_predicate flash[:drawer_alert], :present?
    assert_empty own_types(:checkout)
  end

  should "withdraw a unit's structure, each type beneath it taking a type of the one above" do
    declare_fresh(:checkout, { @org[:squad] => "Squad" })
    group = overview.structures.fetch(@org[:checkout]).first

    get new_tenant_org_unit_structure_withdrawal_path(@org[:checkout])
    assert_equal "Squad", drawer.at_css("select[name='conversion[#{group.id}]'] option[selected]").text

    post tenant_org_unit_structure_withdrawal_path(@org[:checkout]), params: { conversion: { group.id => @org[:squad] } }

    assert_redirected_to tenant_org_graph_path(unit: @org[:checkout])
    assert_empty own_types(:checkout)
    assert_equal @org[:squad], overview.unit(@org[:payments]).level_id
  end

  should "send a move into another structure to a step that asks what each type becomes, then move it" do
    declare_fresh(:checkout, { @org[:squad] => "Group" })
    group = overview.structures.fetch(@org[:checkout]).first

    get edit_tenant_org_unit_path(@org[:platform])
    assert_equal %w[Checkout Payments], drawer.css("#org-unit-parent optgroup option").map { it.text.gsub(/[[:space:]]/, "") }

    patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { parent_id: @org[:checkout] } }
    assert_redirected_to new_tenant_org_unit_structure_move_path(@org[:platform], parent_id: @org[:checkout])

    get new_tenant_org_unit_structure_move_path(@org[:platform], parent_id: @org[:checkout])
    assert_not_includes drawer.text, "one way"
    assert drawer.at_css("select[name='conversion[#{@org[:team]}]']")

    post tenant_org_unit_structure_move_path(@org[:platform]),
         params: { parent_id: @org[:checkout], conversion: { @org[:team] => group.id } }

    assert_redirected_to edit_tenant_org_unit_path(@org[:platform])
    assert_equal "Moved Platform into Checkout's structure. Its type is now Group.", flash[:notice]
    assert_equal @org[:checkout], overview.unit(@org[:platform]).parent_id
    assert_equal "Group", type_of(:platform)
  end

  context "as a tenant member" do
    setup do
      sign_out @admin_user
      sign_in @member_user
    end

    should "not open a structure step, nor change a structure" do
      [ new_tenant_org_unit_structure_declaration_path(@org[:checkout]),
        new_tenant_org_unit_structure_withdrawal_path(@org[:checkout]),
        new_tenant_org_unit_structure_move_path(@org[:platform], parent_id: @org[:checkout]) ].each do |path|
        get path
        assert_redirected_to root_path
      end

      declare_fresh(:checkout, { @org[:squad] => "Group" })
      assert_redirected_to root_path
      assert_empty own_types(:checkout)
    end

    should "neither withdraw a structure nor move a unit into one" do
      sign_out @member_user
      sign_in @admin_user
      declare_fresh(:checkout, { @org[:squad] => "Group" })
      group = overview.structures.fetch(@org[:checkout]).sole
      sign_out @admin_user
      sign_in @member_user

      post tenant_org_unit_structure_withdrawal_path(@org[:checkout]), params: { conversion: { group.id => @org[:squad] } }
      assert_redirected_to root_path
      post tenant_org_unit_structure_move_path(@org[:platform]), params: { parent_id: @org[:checkout], conversion: { @org[:team] => group.id } }
      assert_redirected_to root_path

      assert_equal %w[Group], own_types(:checkout)
      assert_equal "Group", type_of(:payments)
      assert_not_equal @org[:checkout], overview.unit(@org[:platform]).parent_id
      assert_equal "Team", type_of(:platform)
    end
  end
end

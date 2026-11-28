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

    assert_redirected_to edit_tenant_org_structure_path(@org[:checkout])
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

    assert_redirected_to edit_tenant_org_structure_path(@org[:checkout])
    assert_equal %w[Department Team Squad], own_types(:checkout)
    assert_equal "Squad", type_of(:payments)
  end

  should "give a unit new types, each able to sit anywhere in it, and then say so in its drawer" do
    get new_tenant_org_unit_structure_declaration_path(@org[:checkout], fresh: 1)
    assert_equal "Every type can sit anywhere in it for now. Narrow that on the next page.",
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

  should "move a unit out of a structure, each type preselecting the one it held there before (#521)" do
    declare_fresh(:checkout, { @org[:squad] => "Team" })
    assert_equal "Team", type_of(:payments)

    get edit_tenant_org_unit_path(@org[:payments])
    assert_equal %w[None(atthetop) Engineering Platform], drawer.css("#org-unit-parent optgroup option").map { it.text.gsub(/[[:space:]]/, "") }

    get new_tenant_org_unit_structure_move_path(@org[:payments], parent_id: @org[:platform])
    assert_includes drawer.text, "takes it out of Checkout's structure into the organisation's structure"
    assert_includes drawer.text, "Each type in Checkout's structure becomes a type in the organisation's structure"
    held = overview.unit(@org[:payments]).level_id
    assert_equal "Squad", drawer.at_css("select[name='conversion[#{held}]'] option[selected]").text

    post tenant_org_unit_structure_move_path(@org[:payments]), params: { parent_id: @org[:platform], conversion: { held => @org[:squad] } }

    assert_equal "Moved Payments into the organisation's structure. Its type is now Squad.", flash[:notice]
    assert_equal @org[:platform], overview.unit(@org[:payments]).parent_id
    assert_equal @org[:squad], overview.unit(@org[:payments]).level_id
  end

  should "move a unit out of a structure to the top of the organisation's (#521)" do
    declare_fresh(:checkout, { @org[:squad] => "Group" })
    group = overview.structures.fetch(@org[:checkout]).sole

    patch tenant_org_unit_path(@org[:payments]), params: { org_unit: { parent_id: "" } }
    assert_redirected_to new_tenant_org_unit_structure_move_path(@org[:payments], parent_id: "")

    get new_tenant_org_unit_structure_move_path(@org[:payments], parent_id: "")
    assert_includes drawer.text, "Moving Payments to the top of the organisation's structure takes it out of Checkout's structure"
    assert_equal "Squad", drawer.at_css("select[name='conversion[#{group.id}]'] option[selected]").text

    post tenant_org_unit_structure_move_path(@org[:payments]), params: { parent_id: "", conversion: { group.id => @org[:squad] } }

    assert_equal "Moved Payments into the organisation's structure. Its type is now Squad.", flash[:notice]
    assert_equal [ nil, @org[:squad] ], overview.unit(@org[:payments]).then { [ it.parent_id, it.level_id ] }
  end

  should "offer a unit moving to the top only the types that may sit there (#521)" do
    declare_fresh(:checkout, { @org[:squad] => "Squad" })
    ActsAsTenant.with_tenant(@tenant) do
      OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                       .set_kind_parents(@org[:squad], parent_ids: [ @org[:team] ], top: false, effective_on: Date.current)
    end
    held = overview.unit(@org[:payments]).level_id

    get new_tenant_org_unit_structure_move_path(@org[:payments], parent_id: "")

    options = drawer.css("select[name='conversion[#{held}]'] option")
    assert_equal %w[Team], options.map(&:text)
    assert_empty options.css("[selected]")
  end

  should "not turn a parent that is no longer live into a move to the top (#521)" do
    declare_fresh(:checkout, { @org[:squad] => "Group" })

    get new_tenant_org_unit_structure_move_path(@org[:payments], parent_id: SecureRandom.uuid_v7)

    assert_includes drawer.text, "Payments can't move into another structure from here."
    assert_nil drawer.at_css("input[name='parent_id']")
  end

  should "move a unit that declares a structure into another, saying it keeps its own (#521)" do
    declare_fresh(:checkout, { @org[:squad] => "Group" })
    declare_fresh(:platform, [ "Tribe" ])

    get edit_tenant_org_unit_path(@org[:checkout])
    assert_equal %w[Platform], drawer.css("#org-unit-parent optgroup option").map { it.text.gsub(/[[:space:]]/, "") }

    get new_tenant_org_unit_structure_move_path(@org[:checkout], parent_id: @org[:platform])
    assert_includes drawer.text, "takes it out of the organisation's structure into Platform's structure, so it changes type"
    assert_includes drawer.text, "Checkout keeps its own structure, and the units in it keep their types."

    tribe = overview.structures.fetch(@org[:platform]).sole
    post tenant_org_unit_structure_move_path(@org[:checkout]), params: { parent_id: @org[:platform], conversion: { @org[:team] => tribe.id } }

    assert_equal "Moved Checkout into Platform's structure. Its type is now Tribe.", flash[:notice]
    assert_equal "Tribe", type_of(:checkout)
    assert_equal "Group", type_of(:payments)
  end

  context "as Checkout's owner" do
    setup do
      owner_user = create(:user)
      ActsAsTenant.with_tenant(@tenant) do
        create(:tenant_user, tenant: @tenant, user: owner_user, person: @org[:ada], role: :member)
        OrgGraph::StructureCommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                         .add_unit_owner(@org[:checkout], @org[:ada].id, effective_on: "2026-01-01")
      end
      sign_out @admin_user
      sign_in owner_user
    end

    should "open the structure steps for a unit they own, and for none elsewhere" do
      get new_tenant_org_unit_structure_declaration_path(@org[:payments])
      assert_response :success

      [ new_tenant_org_unit_structure_declaration_path(@org[:platform]),
        new_tenant_org_unit_structure_withdrawal_path(@org[:platform]) ].each do |path|
        get path
        assert_redirected_to root_path, path
      end
    end
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

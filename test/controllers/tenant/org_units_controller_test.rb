# frozen_string_literal: true

require "test_helper"

# The unit drawer (#124): Tenant::OrgUnitsController, OrgUnitOwnersController
# and OrgUnitMembersController.
class Tenant::OrgUnitsControllerTest < ActionDispatch::IntegrationTest
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
  end

  def unit(key) = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[key]) }

  def membership(person, key)
    ActsAsTenant.with_tenant(@tenant) { OrgMembership.find_by(person_id: @org[person].id, unit_id: @org[key]) }
  end

  def drawer = Nokogiri::HTML5(response.body).at_css("aside#org-graph-drawer")

  context "as a tenant admin" do
    setup { sign_in @admin_user }

    should "open a unit's drawer over the Units view, with its details, owners and members" do
      get edit_tenant_org_unit_path(@org[:checkout])

      assert_response :success
      assert_equal "Checkout", Nokogiri::HTML5(response.body).at_css("#org-graph-unit").text
      assert_equal "Checkout", drawer.at_css("#org-graph-drawer-title").text
      assert_equal "Checkout", drawer.at_css("input#org-unit-name")["value"]
      assert_equal @org[:engineering], drawer.at_css("select#org-unit-parent option[selected]")["value"]
      parents = drawer.css("select#org-unit-parent option").map(&:text).map(&:strip)
      assert_not_includes parents, "Payments", "a unit can't move beneath its own sub-unit"
      brook = drawer.at_css("#org-unit-member-#{@org[:brook].id}")
      assert_includes brook.text, "Tech lead · 50%"
      assert_equal [ tenant_org_unit_member_path(@org[:checkout], @org[:brook].id) ] * 2,
                   brook.css("form").map { |form| form["action"] }, "a member's forms name the person by id"
      assert_equal Date.current.iso8601, drawer.at_css("input[name='effective_on']")["value"]
      assert_includes drawer.text, "No one owns this unit yet."
    end

    should "offer as parents only the units a level above" do
      get edit_tenant_org_unit_path(@org[:platform])

      assert_equal [ "None (top level)", "Engineering" ],
                   drawer.css("select#org-unit-parent option").map(&:text).map(&:strip)
    end

    should "show an HRIS unit's name and parent as read-only, naming the provider" do
      ActsAsTenant.with_tenant(@tenant) do
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                .set_membership(@org[:ada].id, @org[:engineering], provider: "hibob", effective_on: "2026-01-05")
        OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                                .set_membership(@org[:ezra].id, @org[:engineering], provider: "espalia", effective_on: "2026-01-05")
      end

      get edit_tenant_org_unit_path(@org[:engineering])

      assert_nil drawer.at_css("input#org-unit-name")
      assert_nil drawer.at_css("select#org-unit-parent")
      assert_includes drawer.text, "From HiBob: change its name and parent there."
      hris_row = drawer.at_css("#org-unit-member-#{@org[:ada].id}")
      assert_includes hris_row.text, "From HiBob"
      assert_nil hris_row.at_css("form")
      assert drawer.at_css("#org-unit-member-#{@org[:ezra].id} button[aria-label='Remove Ezra Pell from Engineering']")
      assert drawer.at_css("form[action='#{tenant_org_unit_owners_path(@org[:engineering])}']"), "owners stay editable"
    end

    should "rename a unit from the chosen date and keep that date for the next change" do
      patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" }, effective_on: "2026-11-01" }

      assert_redirected_to edit_tenant_org_unit_path(@org[:platform], on: "2026-11-01")
      assert_equal "Core", unit(:platform).name
      follow_redirect!
      assert_equal "2026-11-01", drawer.at_css("input#org-unit-effective-on")["value"]
    end

    should "move a unit to the root when no parent is chosen" do
      patch tenant_org_unit_path(@org[:payments]), params: { org_unit: { parent_id: "" } }

      assert_redirected_to edit_tenant_org_unit_path(@org[:payments])
      assert_nil unit(:payments).parent_id
    end

    should "bring a guard's refusal back to the drawer and change nothing" do
      patch tenant_org_unit_path(@org[:engineering]), params: { org_unit: { name: "Eng" } }

      assert_redirected_to edit_tenant_org_unit_path(@org[:engineering])
      assert_equal "Engineering", unit(:engineering).name
      follow_redirect!
      assert_equal "HiBob supplies this unit; change it there", drawer.at_css("#org-unit-alert").text.strip
    end

    should "say who may make a change the command refuses" do
      refusal = OrgGraph::Authorization::Refused.new("Only a tenant admin, an Org Graph editor or an owner of Platform can change Platform")
      Operations::OrgGraph::RenameUnit.stub(:call, ->(**) { raise refusal }) do
        patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" } }
      end

      follow_redirect!
      assert_equal refusal.message, drawer.at_css("#org-unit-alert").text.strip
      assert_equal "Platform", unit(:platform).name
    end

    should "add and remove owners" do
      post tenant_org_unit_owners_path(@org[:platform]), params: { person_ids: [ @org[:ada].id, @org[:ezra].id ] }
      assert_redirected_to edit_tenant_org_unit_path(@org[:platform])
      assert_equal [ "Ada Quill", "Ezra Pell" ], unit(:platform).own_owners.order(:name).map(&:name)

      delete tenant_org_unit_owner_path(@org[:platform], @org[:ezra].id)
      assert_response :see_other
      assert_equal [ "Ada Quill" ], unit(:platform).own_owners.map(&:name)
    end

    should "ask for someone when no owner is chosen" do
      post tenant_org_unit_owners_path(@org[:platform])

      follow_redirect!
      assert_equal "Choose someone to own Platform.", drawer.at_css("#org-unit-alert").text.strip
    end

    should "add a member with a role and an allocation given as a percentage" do
      post tenant_org_unit_members_path(@org[:payments]),
           params: { person_ids: [ @org[:ezra].id ], role: "Analyst", allocation: "40" }

      assert_redirected_to edit_tenant_org_unit_path(@org[:payments])
      added = membership(:ezra, :payments)
      assert_equal "Analyst", added.role
      assert_in_delta 0.4, added.allocation
    end

    should "refuse an allocation that isn't a number without placing anyone" do
      post tenant_org_unit_members_path(@org[:payments]), params: { person_ids: [ @org[:ezra].id ], allocation: "lots" }

      assert_nil membership(:ezra, :payments)
      follow_redirect!
      assert_includes drawer.at_css("#org-unit-alert").text, "Allocation must be a number"
    end

    should "move a member to another unit and remove one" do
      patch tenant_org_unit_member_path(@org[:checkout], @org[:cyril].id), params: { unit_id: @org[:payments] }
      assert_redirected_to edit_tenant_org_unit_path(@org[:checkout])
      assert_nil membership(:cyril, :checkout)
      assert membership(:cyril, :payments)

      delete tenant_org_unit_member_path(@org[:payments], @org[:dot].id)
      assert_response :see_other
      assert_nil membership(:dot, :payments)
    end

    should "offer only active people as candidates" do
      get candidates_tenant_org_unit_path(@org[:platform], frame: "owner-candidates", q: "e")

      assert_response :success
      frame = Nokogiri::HTML5(response.body).at_css("turbo-frame#owner-candidates")
      assert_includes frame.text, "Ezra Pell"
      assert_not_includes frame.text, "Faye Lumen"
    end
  end

  context "as a tenant member" do
    setup { sign_in @member_user }

    should "not open the drawer" do
      get edit_tenant_org_unit_path(@org[:platform])

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end

    should "not rename, own or staff a unit" do
      patch tenant_org_unit_path(@org[:platform]), params: { org_unit: { name: "Core" } }
      post tenant_org_unit_owners_path(@org[:platform]), params: { person_ids: [ @org[:ada].id ] }
      delete tenant_org_unit_member_path(@org[:platform], @org[:ada].id)

      assert_equal "Platform", unit(:platform).name
      assert_empty unit(:platform).own_owners
      assert membership(:ada, :platform)
    end

    should "not search people" do
      get candidates_tenant_org_unit_path(@org[:platform], q: "e")

      assert_redirected_to root_path
    end
  end
end

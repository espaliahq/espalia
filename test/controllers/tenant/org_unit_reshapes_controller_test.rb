# frozen_string_literal: true

require "test_helper"

# Retire, merge and split from the unit drawer (#138):
# OrgUnitRetirementsController, OrgUnitMergesController and
# OrgUnitSplitsController.
class Tenant::OrgUnitReshapesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @admin_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin) }
    sign_in @admin_user
  end

  def unit(key) = ActsAsTenant.with_tenant(@tenant) { OrgUnit.find(@org[key]) }

  def units_of(person) = ActsAsTenant.with_tenant(@tenant) { OrgMembership.where(person_id: @org[person].id).map { it.unit.name }.sort }

  def drawer = Nokogiri::HTML5(response.body).at_css("aside#org-graph-drawer")

  def labels(selector) = drawer.css(selector).map { it.text.strip }

  should "offer split, merge and retire in an Espalia unit's drawer, and name the provider in a mirrored one" do
    get edit_tenant_org_unit_path(@org[:platform])
    assert_equal [ "Split", "Merge", "Retire" ], labels("section[aria-labelledby='org-unit-reshape'] a")

    get edit_tenant_org_unit_path(@org[:engineering])
    assert_empty drawer.css("section[aria-labelledby='org-unit-reshape'] a")
    assert_includes drawer.at_css("section[aria-labelledby='org-unit-reshape']").text,
                    "HiBob holds Engineering, so split, merge or retire it there."
  end

  context "retire" do
    should "say how many memberships end, then retire the unit" do
      get new_tenant_org_unit_retirement_path(@org[:payments])

      assert_includes drawer.at_css("#org-unit-retire-summary").text, "ends 1 membership"
      assert_equal [ "Dot Fennick" ], labels("ul[aria-label='People leaving Payments'] li span:first-child")

      post tenant_org_unit_retirement_path(@org[:payments]), params: { effective_on: "2026-11-02" }

      assert_redirected_to tenant_org_graph_path(unit: @org[:checkout])
      assert_equal "Retired Payments. 1 membership ended.", flash[:notice]
      assert unit(:payments).retired?
      assert_empty units_of(:dot)
    end

    should "refuse a unit with live sub-units, and say which" do
      get new_tenant_org_unit_retirement_path(@org[:checkout])

      assert_equal "Move or retire Checkout's sub-units first: Payments.", drawer.at_css("#org-unit-step-blocked").text
      assert_empty drawer.css("form[action='#{tenant_org_unit_retirement_path(@org[:checkout])}']")

      post tenant_org_unit_retirement_path(@org[:checkout])

      assert_redirected_to new_tenant_org_unit_retirement_path(@org[:checkout])
      assert_equal "Move or retire Checkout's sub-units first: Payments", flash[:drawer_alert]
      assert_not unit(:checkout).retired?
    end

    should "name the provider that holds a mirrored unit" do
      get new_tenant_org_unit_retirement_path(@org[:engineering])

      assert_equal "HiBob holds Engineering, so split, merge or retire it there.",
                   drawer.at_css("#org-unit-step-blocked").text
    end
  end

  context "merge" do
    should "move everyone to the unit that carries on" do
      get new_tenant_org_unit_merge_path(@org[:payments])

      assert_includes drawer.text, "1 person in Payments moves to it"
      targets = labels("select#org-unit-merge-into option").drop(1).map { it.delete("\u2003") }
      assert_includes targets, "Platform"
      assert_not_includes targets, "Payments"
      assert_not_includes targets, "Engineering", "HiBob holds Engineering's shape"

      post tenant_org_unit_merge_path(@org[:payments]), params: { into_unit_id: @org[:platform], effective_on: "2026-11-02" }

      assert_redirected_to edit_tenant_org_unit_path(@org[:platform])
      assert_equal "Merged Payments into Platform.", flash[:notice]
      assert unit(:payments).retired?
      assert_equal [ "Platform" ], units_of(:dot)
    end

    should "say so when there is no unit to merge into" do
      [ :payments, :checkout ].each { |key| post tenant_org_unit_retirement_path(@org[key]) }

      get new_tenant_org_unit_merge_path(@org[:platform])

      assert_equal "There's no other unit you can merge Platform into.", drawer.at_css("#org-unit-step-blocked").text
    end

    should "come back to the step with the reason when no unit is chosen" do
      post tenant_org_unit_merge_path(@org[:payments]), params: { into_unit_id: "" }

      assert_redirected_to new_tenant_org_unit_merge_path(@org[:payments])
      assert_match(/into_unit_id/, flash[:drawer_alert])
      assert_not unit(:payments).retired?
    end
  end

  context "split" do
    should "name the new units, place people, and list who will be in no team before splitting" do
      get new_tenant_org_unit_split_path(@org[:platform])
      assert_equal 3, drawer.css("input[name='names[]']").size

      get new_tenant_org_unit_split_path(@org[:platform]), params: { stage: "place", names: [ "Core", "Edge", "" ] }
      assert_equal [ "No team", "Core", "Edge" ], labels("select#org-unit-split-place-#{@org[:ada].id} option")

      get new_tenant_org_unit_split_path(@org[:platform]),
          params: { stage: "review", names: %w[Core Edge], placements: { @org[:ada].id => "Core", @org[:brook].id => "" } }
      assert_equal [ "Ada Quill" ], labels("ul[aria-label='Moving to Core'] li span:first-child")
      assert_equal [ "Brook Tamsin" ], labels("ul[aria-label='Will be in no team'] li span:first-child")

      post tenant_org_unit_split_path(@org[:platform]),
           params: { names: %w[Core Edge], placements: { @org[:ada].id => "Core" }, effective_on: "2026-11-02" }

      assert_redirected_to tenant_org_graph_path(unit: @org[:engineering])
      assert_equal "Split Platform into Core and Edge.", flash[:notice]
      assert unit(:platform).retired?
      assert_equal [ "Core" ], units_of(:ada)
      assert_equal [ "Checkout" ], units_of(:brook)
    end

    should "keep asking for names until there are two different ones" do
      get new_tenant_org_unit_split_path(@org[:platform]), params: { stage: "place", names: [ "Core", "" ] }
      assert_equal "Name at least two new units.", drawer.at_css("#org-unit-split-problem").text

      get new_tenant_org_unit_split_path(@org[:platform]), params: { stage: "place", names: %w[Core core] }
      assert_equal "Give each new unit a different name.", drawer.at_css("#org-unit-split-problem").text
      assert_equal %w[Core core], drawer.css("input[name='names[]']").first(2).map { it["value"] }
    end

    should "come back to the review with the reason when the split is refused" do
      post tenant_org_unit_split_path(@org[:checkout]), params: { names: %w[Web Mobile] }

      assert_response :redirect
      assert_match "stage=review", response.location
      assert_equal "Move or retire Checkout's sub-units first: Payments", flash[:drawer_alert]
    end
  end
end

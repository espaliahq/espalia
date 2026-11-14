# frozen_string_literal: true

require "test_helper"

# "Still true" (#142): stale flags in the Units view and both drawers, and
# the confirmation they post.
class Tenant::OrgFactConfirmationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include OrgGraphFixture

  setup do
    @tenant = create(:tenant)
    @org = build_org_graph(@tenant)
    @admin_user = create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                           person: create(:person, tenant: @tenant, name: "Gil Ostrom"))
      OrgGraph::CommandHandler.new(actor: OrgGraph::Authorization::SYSTEM)
                              .change_site(@org[:brook].id, site: "Harbour", country: "AU", **PROVENANCE)
    end
    sign_in @admin_user
  end

  def page = Nokogiri::HTML5(response.body)

  def flags = page.css("[data-stale-flag]").map { |flag| flag["data-stale-flag"] }

  should "show nothing stale within the threshold" do
    get tenant_org_graph_path(unit: @org[:checkout])

    assert_empty flags
  end

  should "flag stale memberships in the Units view, the unit drawer and the person drawer" do
    travel 91.days

    get tenant_org_graph_path(unit: @org[:checkout])
    assert_includes flags, "Cyril Moss's membership of Checkout"

    get edit_tenant_org_unit_path(@org[:checkout])
    assert_includes page.at_css("aside#org-graph-drawer").css("[data-stale-flag]").map { it["data-stale-flag"] },
                    "Cyril Moss's membership of Checkout"

    get tenant_org_person_path(@org[:brook])
    drawer = page.at_css("aside#org-graph-drawer").css("[data-stale-flag]").map { it["data-stale-flag"] }
    assert_includes drawer, "membership of Platform"
    assert_includes drawer, "site"
  end

  should "confirm a membership as of today and go back to the Units view" do
    travel 91.days

    post tenant_org_person_confirmations_path(@org[:cyril]),
         params: { facts: [ "membership" ], unit_id: @org[:checkout], return_to: "units", unit: @org[:checkout] }

    assert_redirected_to tenant_org_graph_path(unit: @org[:checkout])
    follow_redirect!
    assert_not_includes flags, "Cyril Moss's membership of Checkout"
  end

  should "keep the Units view's comparison open across Still true" do
    travel 91.days
    window = { from: 30.days.ago.to_date.iso8601, by: "learned" }

    get tenant_org_graph_path(unit: @org[:checkout], **window)
    form = page.at_css("[data-stale-flag=\"Cyril Moss's membership of Checkout\"] form")
    assert_equal window.stringify_keys, form.css("input[name=from], input[name=to], input[name=by]").to_h { [ it["name"], it["value"] ] }

    post tenant_org_person_confirmations_path(@org[:cyril]),
         params: { facts: [ "membership" ], unit_id: @org[:checkout], return_to: "units", unit: @org[:checkout], **window }
    assert_redirected_to tenant_org_graph_path(unit: @org[:checkout], **window)
  end

  should "keep the comparison across Still true in the unit drawer and the person drawer" do
    travel 91.days
    window = { from: 30.days.ago.to_date.iso8601, by: "learned" }

    get edit_tenant_org_unit_path(@org[:checkout], **window)
    form = page.at_css("aside#org-graph-drawer [data-stale-flag=\"Cyril Moss's membership of Checkout\"] form")
    assert_equal window.stringify_keys, form.css("input[name=from], input[name=by]").to_h { [ it["name"], it["value"] ] }
    post tenant_org_person_confirmations_path(@org[:cyril]),
         params: { facts: [ "membership" ], unit_id: @org[:checkout], return_to: "unit", unit: @org[:checkout], **window }
    assert_redirected_to edit_tenant_org_unit_path(@org[:checkout], **window)

    get tenant_org_person_path(@org[:brook], **window)
    form = page.at_css("aside#org-graph-drawer [data-stale-flag='site'] form")
    assert_equal window.stringify_keys, form.css("input[name=from], input[name=by]").to_h { [ it["name"], it["value"] ] }
    post tenant_org_person_confirmations_path(@org[:brook]), params: { facts: %w[site country], **window }
    assert_redirected_to tenant_org_person_path(@org[:brook], **window)
  end

  should "confirm a pair of facts together and go back to the person drawer" do
    travel 91.days

    post tenant_org_person_confirmations_path(@org[:brook]), params: { facts: %w[site country] }

    assert_redirected_to tenant_org_person_path(@org[:brook])
    follow_redirect!
    assert_not_includes flags, "site"
  end

  should "keep the drawer's chosen date when going back to it" do
    travel 91.days
    get tenant_org_person_path(@org[:brook])
    assert_equal Date.current.iso8601,
                 page.at_css("[data-stale-flag='site'] input[name='effective_on']")["value"]

    post tenant_org_person_confirmations_path(@org[:brook]), params: { facts: %w[site country], effective_on: "2026-12-01" }

    assert_redirected_to tenant_org_person_path(@org[:brook], on: "2026-12-01")
  end

  should "keep the unit drawer's chosen date when going back to it" do
    travel 91.days
    get edit_tenant_org_unit_path(@org[:checkout], on: "2026-12-01")
    assert_equal "2026-12-01",
                 page.at_css("[data-stale-flag=\"Cyril Moss's membership of Checkout\"] input[name='effective_on']")["value"]

    post tenant_org_person_confirmations_path(@org[:cyril]),
         params: { facts: [ "membership" ], unit_id: @org[:checkout], return_to: "unit", unit: @org[:checkout],
                   effective_on: "2026-12-01" }

    assert_redirected_to edit_tenant_org_unit_path(@org[:checkout], on: "2026-12-01")
  end

  should "come back to the unit drawer with the reason when a confirmation is refused" do
    post tenant_org_person_confirmations_path(@org[:cyril]),
         params: { facts: [ "membership" ], unit_id: @org[:engineering], return_to: "unit", unit: @org[:checkout] }

    assert_redirected_to edit_tenant_org_unit_path(@org[:checkout])
    assert flash[:drawer_alert].present?
  end

  should "go back to the person drawer when asked for the unit drawer with no unit" do
    travel 91.days

    post tenant_org_person_confirmations_path(@org[:cyril]),
         params: { facts: [ "membership" ], unit_id: @org[:checkout], return_to: "unit" }

    assert_redirected_to tenant_org_person_path(@org[:cyril])
  end

  should "refuse a member who may not see the org graph and leave the fact unconfirmed" do
    travel 91.days
    member = create(:user)
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: member, role: :member) }
    sign_in member
    checked_on = -> { ActsAsTenant.with_tenant(@tenant) { OrgFactAge.find_by!(person: @org[:cyril], unit: @org[:checkout]).checked_at } }
    before = checked_on.call

    post tenant_org_person_confirmations_path(@org[:cyril]),
         params: { facts: [ "membership" ], unit_id: @org[:checkout], return_to: "units", unit: @org[:checkout] }

    assert_redirected_to root_path
    assert_equal "You are not authorized to perform this action.", flash[:alert]
    assert_equal before, checked_on.call
  end
end

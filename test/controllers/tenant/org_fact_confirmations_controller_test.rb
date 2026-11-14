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

  should "confirm a pair of facts together and go back to the person drawer" do
    travel 91.days

    post tenant_org_person_confirmations_path(@org[:brook]), params: { facts: %w[site country] }

    assert_redirected_to tenant_org_person_path(@org[:brook])
    follow_redirect!
    assert_not_includes flags, "site"
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
end

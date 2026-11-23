# frozen_string_literal: true

require "application_system_test_case"

class Tenant::OrgGraphOrganisationActivitySystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  SIDEBAR = "##{Views::Tenant::OrgGraph::Sidebar::ID}".freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
                                              person: FactoryBot.create(:person, tenant: @tenant, name: "Ada Admin"))
      editor = FactoryBot.create(:tenant_user, tenant: @tenant,
                                               person: FactoryBot.create(:person, tenant: @tenant, name: "Rowan Grant"))
      AccountGrants::CommandHandler.new.add(:org_graph_editor, editor, added_by_id: admin.person_id)
    end
  end

  def assert_grant_shown
    within(SIDEBAR) do
      assert_selector "h2", text: /\Aorganisation activity\z/i
      assert_text "Made Rowan Grant an Org Graph editor"
      assert_text "Ada Admin"
      assert_text "Can't change back: #{OrgGraph::ChangeBackHandler::GRANT}"
      assert_no_selector "button", text: /Change/
    end
  end

  context "at desktop width" do
    setup { page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE) }

    should "show the organisation's activity when no unit is open" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path

      assert_text "No units yet"
      assert_grant_shown
      screenshot("organisation_activity")
    end

    should "open the organisation's activity from a unit's, and go back" do
      org = build_org_graph(@tenant)
      sign_in_as(@admin_user)
      visit tenant_org_graph_path(unit: org[:platform])
      within(SIDEBAR) { assert_text "Added Ada Quill" }

      click_with_retry(expect_text: "Made Rowan Grant an Org Graph editor") { within(SIDEBAR) { click_link "Organisation activity" } }
      assert_grant_shown
      assert_operator find("#org-graph-unit").rect.x, :<, find(SIDEBAR).rect.x, "the sidebar stays beside the unit"

      click_with_retry(expect_text: "Added Ada Quill") { within(SIDEBAR) { click_link "Back to Platform's activity" } }
      within(SIDEBAR) { assert_text "Added Ada Quill" }
    end
  end

  context "at phone width" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "show the organisation's activity when no unit is open, with no sideways scroll" do
      sign_in_as(@admin_user)
      visit tenant_org_graph_path

      assert_grant_shown
      screenshot("organisation_activity_phone")
      assert_no_sideways_overflow
      assert_no_stolen_taps
    end
  end
end

# frozen_string_literal: true

require "application_system_test_case"

class IntegrationsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant, :with_hibob_config)
    @admin_user  = FactoryBot.create(:user, password: "password123")
    @member_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      FactoryBot.create(:person,
        tenant: @tenant,
        name: "Alice Engineer",
        email: "alice@example.com",
        job_title: "Software Engineer",
        department: "Engineering",
        hris_source: "hibob",
        status: "active"
      )
      FactoryBot.create(:person,
        tenant: @tenant,
        name: "Bob NoMatch",
        email: "bob@example.com",
        job_title: "Galactic Architect",
        department: "Research",
        hris_source: "hibob",
        status: "active"
      )
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  end

  context "as a tenant admin" do
    should "show Admin link in the navbar" do
      sign_in @admin_user
      visit root_path
      screenshot("admin_navbar")

      assert_link "Admin"
      assert_no_link "Integrations" # surfaced inside /tenant, not the top nav
    end

    should "render the integrations index page" do
      sign_in @admin_user
      visit tenant_integrations_path
      screenshot("integrations_index")

      assert_text "HRIS"
      assert_text "Hibob"
      assert_text "Active"
    end

    should "render the HRIS detail page with config, mappings, and people" do
      sign_in @admin_user
      visit tenant_integration_path("hris")
      screenshot("integrations_hris_show")

      assert_text "HRIS Integration"
      assert_text "Configuration"
      assert_text "Role Mappings"
      assert_text "Imported People"

      # Configuration values — DescriptionList terms are CSS-uppercased
      assert_text "PROVIDER"
      assert_text "SYNC ENABLED"
      assert_text "Hibob"

      # Mapping table — seeded with Software Engineer → E
      assert_text "Software Engineer"
      assert_text "Engineering Manager"

      # People table
      assert_text "Alice Engineer"
      assert_text "alice@example.com"
      assert_text "Engineering"
      assert_text "Bob NoMatch"
      assert_text "Galactic Architect"
      assert_text "Research"
      assert_text "Unmapped title"
    end

    should "show Sync now button" do
      sign_in @admin_user
      visit tenant_integration_path("hris")

      assert_button "Sync now"
    end
  end

  context "as a tenant member" do
    should "not show Admin link in the navbar" do
      sign_in @member_user
      visit root_path
      screenshot("member_navbar")

      assert_no_link "Admin"
      assert_no_link "Integrations"
    end

    should "redirect away from /tenant/integrations with unauthorized flash" do
      sign_in @member_user
      visit tenant_integrations_path
      screenshot("member_denied")

      # Denied access redirects to the Home dashboard, which shows the flash.
      assert_current_path root_path
      assert_text "You are not authorized to perform this action"
    end
  end

  context "mobile viewport" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "expose Admin link via the mobile sidebar for admins" do
      sign_in @admin_user
      visit root_path
      toggle_sidebar
      screenshot("mobile_sidebar_admin")

      assert_link "Admin"
    end

    should "not expose Admin link via the mobile sidebar for members" do
      sign_in @member_user
      visit root_path
      toggle_sidebar
      screenshot("mobile_sidebar_member")

      assert_no_link "Admin"
    end
  end

  private

  def sign_in(user)
    sign_in_as(user)
  end
end

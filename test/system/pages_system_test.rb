# frozen_string_literal: true

require "application_system_test_case"

class PagesSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    # Reset to desktop viewport before each test — the browser window is shared
    # across tests, so a mobile resize in one test would persist to the next.
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    visit new_user_session_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end

  context "index page" do
    should "render the dashboard shell" do
      visit root_path

      assert_selector "nav", minimum: 1
      assert_text "GrowthOS"
      assert_text "Welcome to GrowthOS"
    end

    should "display stat cards" do
      visit root_path

      assert_text "Streak"
      assert_text "Points"
      assert_text "Goals"
    end

    should "show sidebar on desktop" do
      # Default screen size is 1400x1400 (desktop)
      visit root_path

      assert_selector "[data-sidebar-target='drawer']", visible: true
      assert_selector "aside nav", visible: true
    end

    should "hide sidebar by default on mobile and toggle it with hamburger" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit root_path

      # Use visible: :all because the drawer starts hidden on mobile
      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      assert drawer[:class].include?("hidden"), "sidebar drawer should be hidden on mobile by default"

      find("[data-action='sidebar#toggle']").click

      assert_not find("[data-sidebar-target='drawer']", visible: :all)[:class].include?("hidden"),
        "sidebar drawer should be visible after hamburger click"
    end

    should "hide hamburger button on desktop" do
      visit root_path

      # md:hidden applies display:none at md+ — button should not be visible
      assert_no_selector "[data-action='sidebar#toggle']"
    end
  end
end

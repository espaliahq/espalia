# frozen_string_literal: true

require "application_system_test_case"

class PagesSystemTest < ApplicationSystemTestCase
  setup do
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

    should "show nav links in navbar on desktop" do
      visit root_path

      within "nav" do
        assert_text "Home"
        assert_text "Frameworks"
      end
    end

    should "hide sidebar drawer by default on mobile and toggle it with hamburger" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit root_path

      # Drawer starts hidden on mobile (has "hidden" class)
      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      classes = drawer[:class].split
      assert_includes classes, "hidden", "sidebar drawer should be hidden on mobile by default"

      find("[data-action='sidebar#toggle']").click

      # After toggle, "hidden" class should be removed (md:hidden still present but doesn't apply on mobile)
      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      classes = drawer[:class].split
      assert_not_includes classes, "hidden",
        "sidebar drawer should be visible after hamburger click"
    end

    should "close mobile menu when clicking outside" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit root_path

      # Open the drawer
      find("[data-action='sidebar#toggle']").click
      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      assert_not_includes drawer[:class].split, "hidden"

      # Click outside the drawer (right side of viewport, past the 16rem drawer)
      page.driver.browser.action.move_to_location(350, 400).click.perform

      # Drawer should close
      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      assert_includes drawer[:class].split, "hidden",
        "sidebar drawer should close when clicking outside"
    end

    should "hide hamburger button on desktop" do
      visit root_path

      # md:hidden applies display:none at md+ — button should not be visible
      assert_no_selector "[data-action='sidebar#toggle']"
    end
  end
end

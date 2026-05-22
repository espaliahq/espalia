# frozen_string_literal: true

require "application_system_test_case"

class PagesSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    sign_in_as(@user)
  end

  context "root redirect" do
    should "redirect to frameworks when the user has no assessments" do
      visit root_path

      assert_current_path frameworks_path
    end

    should "redirect to assessments when the user has at least one assignment" do
      ActsAsTenant.with_tenant(@tenant) do
        # sign_in_as triggers a request that auto-links a Person to the
        # tenant_user via email; reuse it rather than creating a duplicate.
        person = Person.find_or_create_by!(tenant: @tenant, email: @user.email) do |p|
          p.name = @user.email
        end
        FactoryBot.create(:person_framework_assignment, tenant: @tenant, person_id: person.id)
      end

      visit root_path

      assert_current_path assessments_path
    end
  end

  context "page layout shell on /frameworks" do
    should "hide sidebar drawer by default on mobile and toggle it with hamburger" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit frameworks_path

      assert_selector "[data-sidebar-target='drawer']", visible: :all
      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      classes = drawer[:class].split
      assert_includes classes, "hidden", "sidebar drawer should be hidden on mobile by default"

      toggle_sidebar

      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      classes = drawer[:class].split
      assert_not_includes classes, "hidden",
        "sidebar drawer should be visible after hamburger click"
    end

    should "close mobile menu when clicking outside" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit frameworks_path

      toggle_sidebar

      # JS-dispatched MouseEvent bubbles to the window capture-phase listener
      # stimulus-use's useClickOutside registers. Selenium's synthetic pointer
      # events (action.move_to_location.click) do not reliably trigger that
      # listener on headless Chrome under load — same fix as the framework
      # explorer outside-click test.
      dispatch_outside_click = lambda do
        page.execute_script(<<~JS)
          const main = document.querySelector("main") || document.body;
          main.dispatchEvent(new MouseEvent("click", {
            bubbles: true, cancelable: true, view: window
          }))
        JS
      end

      dispatch_outside_click.call

      drawer_visible = -> {
        find("[data-sidebar-target='drawer']", visible: :all)[:class].split.exclude?("hidden")
      }
      dispatch_outside_click.call if drawer_visible.call

      drawer = find("[data-sidebar-target='drawer']", visible: :all)
      assert_includes drawer[:class].split, "hidden",
        "sidebar drawer should close when clicking outside"
    end

    should "hide hamburger button on desktop" do
      visit frameworks_path

      assert_no_selector "[data-action='sidebar#toggle']"
    end
  end
end

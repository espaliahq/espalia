# frozen_string_literal: true

require "application_system_test_case"

class UserMenuSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant, name: "Acme Corp")
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    sign_in_as(@user)
  end

  context "user menu dropdown" do
    should "show user initial in trigger" do
      visit root_path
      screenshot("user_initial_visible")

      initial = @user.email.chr.upcase
      assert_selector "[data-action='dropdown#toggle']", text: initial
    end

    should "open dropdown with email and sign out" do
      visit root_path
      open_dropdown(scope: "#user-menu")
      screenshot("dropdown_open")

      assert_text @user.email
      assert_text "Sign out"
    end

    should "close dropdown when clicking outside" do
      visit root_path
      open_dropdown(scope: "#user-menu")

      # Outside-click is handled by stimulus-use's useClickOutside which
      # registers a window capture-phase listener. Selenium's synthetic
      # pointer events don't reliably trigger that listener on headless
      # Chrome under load, so dispatch a real MouseEvent via JS — same
      # technique used in framework_explorer_system_test.rb.
      page.execute_script(<<~JS)
        const main = document.querySelector("main");
        main.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
      JS

      screenshot("dropdown_closed_after_outside_click")

      assert_no_selector "[role='menu']", visible: true
    end

    should "sign out via dropdown" do
      visit root_path
      open_dropdown(scope: "#user-menu")
      # Submit the Sign out form via requestSubmit() — Capybara's click_on
      # has been dropped on starved CI runners. requestSubmit dispatches a
      # synchronous submit event that Turbo intercepts, bypassing pointer
      # hit-testing entirely.
      page.execute_script(<<~JS)
        const btn = Array.from(document.querySelectorAll("[role='menu'] button, [role='menu'] a"))
          .find(el => el.textContent.trim() === "Sign out");
        if (btn?.tagName === "BUTTON") {
          btn.closest("form")?.requestSubmit(btn);
        } else {
          btn?.click();
        }
      JS
      screenshot("after_sign_out")

      assert_current_path new_user_session_path
    end
  end

  context "tenant switcher" do
    should "not show tenant switcher for single-tenant user" do
      visit root_path
      open_dropdown(scope: "#user-menu")
      screenshot("single_tenant_no_switcher")

      assert_no_text "switch workspace"
    end

    should "show tenant switcher for multi-tenant user" do
      second_tenant = FactoryBot.create(:tenant, name: "Beta Inc")
      ActsAsTenant.with_tenant(second_tenant) do
        FactoryBot.create(:tenant_user, tenant: second_tenant, user: @user)
      end

      visit root_path
      open_dropdown(scope: "#user-menu")
      screenshot("multi_tenant_switcher")

      assert_text "SWITCH WORKSPACE"
      assert_text "Acme Corp"
      assert_text "Beta Inc"
    end

    should "switch tenant when clicking another tenant" do
      second_tenant = FactoryBot.create(:tenant, name: "Beta Inc")
      ActsAsTenant.with_tenant(second_tenant) do
        FactoryBot.create(:tenant_user, tenant: second_tenant, user: @user)
      end

      visit root_path
      open_dropdown(scope: "#user-menu")
      screenshot("before_tenant_switch")

      # Click the switch button for Beta Inc. The open menu's "SWITCH
      # WORKSPACE" heading going invisible is the signal the POST landed and
      # the page re-rendered — we start ON root_path, so the path alone can
      # never tell a dropped click from a successful switch.
      click_button_with_js_fallback("Beta Inc", expect_no_text: "SWITCH WORKSPACE")
      screenshot("after_tenant_switch")

      # Switching tenants returns to the Home dashboard...
      assert_current_path root_path

      # ...and Beta Inc is now the active workspace: the switcher renders the
      # current tenant as a plain checkmarked row, not a submit button.
      open_dropdown(scope: "#user-menu")
      assert_selector "div[role='menuitem']", text: "Beta Inc"
    end
  end
end

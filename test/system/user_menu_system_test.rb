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
      sign_out_from_menu
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

  context "appearance" do
    setup { emulate_os_scheme("dark") }
    teardown do
      emulate_os_scheme("light")
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    end

    should "paint the chosen scheme at once, keep it on reload, and follow the OS again on Auto" do
      visit root_path
      assert_text "Home"
      os_dark = page_background
      assert_checked_scheme "Auto"

      choose_scheme "Light"
      assert_equal "light", html_scheme
      assert_not_equal os_dark, page_background
      light = page_background
      assert_equal [ nil ], theme_color_media, "one theme-color tag, for the chosen scheme"
      assert_saved_scheme "light"
      screenshot("light_chosen")

      visit root_path
      assert_text "Home"
      assert_equal "light", html_scheme
      assert_equal light, page_background
      assert_equal [ nil ], theme_color_media
      assert_checked_scheme "Light"

      choose_scheme "Dark"
      assert_equal "dark", html_scheme
      assert_equal os_dark, page_background
      assert_saved_scheme "dark"
      screenshot("dark_chosen")

      choose_scheme "Auto"
      assert_nil html_scheme
      assert_equal os_dark, page_background
      assert_equal [ "(prefers-color-scheme: light)", "(prefers-color-scheme: dark)" ], theme_color_media
      assert_saved_scheme "auto"
    end

    should "reach and choose a scheme from the keyboard" do
      visit root_path
      assert_text "Home"
      open_dropdown(scope: "#user-menu")

      page.execute_script(<<~JS)
        [...document.querySelectorAll("#user-menu [role='menuitemradio']")].find(el => el.textContent === "Dark").focus()
      JS
      assert_equal "Dark", evaluate_script("document.activeElement.textContent"), "the option takes focus"
      screenshot("dark_focused")
      # A real Enter on a focused button: the native activation is what's under test. A starved runner can
      # drop the key, so press once more if it didn't land; Enter on the checked option changes nothing.
      2.times do
        find("#user-menu [role='menuitemradio']", text: "Dark").send_keys(:enter)
        break if page.has_css?("#user-menu [role='menuitemradio'][aria-checked='true']", exact_text: "Dark", wait: 5)
      end

      assert_checked_scheme "Dark"
      assert_saved_scheme "dark"
      assert_selector "#user-menu [role='group'][aria-labelledby='color-scheme-label']"
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      screenshot("mobile_open")
      assert_selector "#user-menu [role='menuitemradio']", count: 3, visible: true
      assert_equal "Appearance", evaluate_script("document.getElementById('color-scheme-label').textContent")
    end

    should "drop a Dark scheme on a Turbo visit to a page that follows the OS" do
      @tenant.update!(theme: "bento")
      @user.update!(color_scheme: :dark)
      emulate_os_scheme("light")
      visit root_path
      assert_text "Home"
      assert_equal "dark", html_scheme

      sign_out_from_menu
      assert_current_path new_user_session_path

      assert_equal "bento", evaluate_script("document.documentElement.dataset.theme ?? null")
      assert_nil html_scheme
    end

    should "carry a scheme chosen in the menu through the next Turbo visit without a reload" do
      visit root_path
      assert_text "Home"
      choose_scheme "Dark"
      assert_saved_scheme "dark"
      page.execute_script("window.sameDocument = true")

      page.execute_script("Turbo.visit(arguments[0])", settings_notifications_path)
      assert_current_path settings_notifications_path

      assert_equal "dark", html_scheme
      assert evaluate_script("window.sameDocument === true"), "the visit kept the document"
    end

    should "put the saved scheme back when the save never reaches the server" do
      visit root_path
      assert_text "Home"
      hold_scheme_requests

      choose_scheme "Dark"
      assert_equal "dark", html_scheme
      settle_scheme_request 0, :network_error

      assert_checked_scheme "Auto"
      assert_nil html_scheme
      assert_equal [ "(prefers-color-scheme: light)", "(prefers-color-scheme: dark)" ], theme_color_media
      assert @user.reload.color_scheme_auto?
    end

    should "let only the latest choice decide when two saves overlap" do
      visit root_path
      assert_text "Home"
      hold_scheme_requests

      choose_scheme "Light"
      choose_scheme "Dark"
      settle_scheme_request 0, :rejected
      settle_scheme_request 1, :saved

      assert_saved_scheme "dark"
      assert_checked_scheme "Dark"
      assert_equal "dark", html_scheme
    end

    should "send overlapping saves one at a time, so the server keeps the latest choice" do
      visit root_path
      assert_text "Home"
      hold_scheme_requests

      choose_scheme "Light"
      choose_scheme "Dark"
      assert_equal 1, evaluate_script("window.heldSchemeRequests.length"), "the second save waits for the first"

      settle_scheme_request 0, :saved
      settle_scheme_request 1, :saved

      assert_saved_scheme "dark"
    end
  end

  private

  def sign_out_from_menu
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
  end

  def emulate_os_scheme(scheme)
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ]
    )
  end

  def choose_scheme(label)
    open_dropdown(scope: "#user-menu") unless page.has_selector?("#user-menu [role='menu']", visible: true, wait: 0)
    wait_for_stimulus "color-scheme", scope: "#user-menu"
    page.execute_script(<<~JS, label)
      [...document.querySelectorAll("#user-menu [role='menuitemradio']")].find(el => el.textContent === arguments[0]).click()
    JS
    assert_checked_scheme label
  end

  def assert_checked_scheme(label)
    assert_selector "#user-menu [role='menuitemradio'][aria-checked='true']", text: label, exact_text: true, visible: :all
  end

  def assert_saved_scheme(value)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until @user.reload.color_scheme == value
    end
  end

  def html_scheme = evaluate_script("document.documentElement.dataset.scheme ?? null")

  # Parks each save to /settings/color_scheme until settle_scheme_request says how it ends
  def hold_scheme_requests
    page.execute_script(<<~JS)
      const send = window.fetch.bind(window)
      window.heldSchemeRequests = []
      window.fetch = (url, options) => {
        if (!String(url).includes("/settings/color_scheme")) return send(url, options)
        return new Promise((resolve, reject) => {
          window.heldSchemeRequests.push({
            saved: () => send(url, options).then(resolve, reject),
            rejected: () => resolve(new Response(null, { status: 422 })),
            network_error: () => reject(new TypeError("Failed to fetch"))
          })
        })
      }
    JS
  end

  def settle_scheme_request(index, outcome)
    Timeout.timeout(Capybara.default_max_wait_time) do
      sleep 0.05 until evaluate_script("window.heldSchemeRequests.length > arguments[0]", index)
    end
    page.execute_script("window.heldSchemeRequests[arguments[0]][arguments[1]]()", index, outcome.to_s)
  end

  # Finishes running transitions first, so a colour mid-change never reads as the settled one
  def page_background
    evaluate_script(<<~JS)
      (() => {
        document.getAnimations().forEach(animation => animation.finish())
        return getComputedStyle(document.querySelector(".bg-page")).backgroundColor
      })()
    JS
  end

  def theme_color_media
    evaluate_script("[...document.querySelectorAll('meta[name=theme-color]')].map(m => m.getAttribute('media'))")
  end
end

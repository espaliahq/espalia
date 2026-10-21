# frozen_string_literal: true

require "application_system_test_case"

# Pins the cross-cutting accessibility affordances baked into the shared
# layout / navbar / sidebar: a document language, a keyboard skip link, and
# touch targets that meet WCAG 2.5.5 (44x44 CSS px). These regressions are
# invisible to the unit suite and only surface in a real browser.
class AccessibilitySystemTest < ApplicationSystemTestCase
  include ContrastHelpers

  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    sign_in_as(@user)
  end

  context "document language (WCAG 3.1.1)" do
    should "set a lang attribute on <html>" do
      visit root_path
      assert_text "Home"

      assert_equal "en", page.evaluate_script("document.documentElement.getAttribute('lang')")
    end
  end

  context "skip link (WCAG 2.4.1)" do
    should "expose a skip link that targets main content and is hidden until focused" do
      visit root_path
      assert_text "Home"

      assert_selector "a[href='#main-content']", text: "Skip to main content", visible: :all
      assert_selector "main#main-content", visible: :all

      # sr-only until focused: zero-area in the layout, non-zero once focused
      hidden_area = page.evaluate_script(<<~JS)
        (() => { const a=[...document.querySelectorAll('a')].find(x=>x.getAttribute('href')==='#main-content');
                 const r=a.getBoundingClientRect(); return r.width*r.height; })()
      JS
      assert hidden_area <= 1, "skip link should be visually hidden by default"

      focused_area = page.evaluate_script(<<~JS)
        (() => { const a=[...document.querySelectorAll('a')].find(x=>x.getAttribute('href')==='#main-content');
                 a.focus(); const r=a.getBoundingClientRect(); return r.width*r.height; })()
      JS
      assert focused_area > 1, "skip link should become visible on keyboard focus"
    end
  end

  context "touch target sizes on mobile (WCAG 2.5.5)" do
    should "render navbar icon buttons and drawer links at >= 44x44px" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit frameworks_path
      assert_selector "[data-sidebar-target='drawer']", visible: :all

      hamburger = min_dimension("button[aria-label='Toggle navigation']")
      assert hamburger >= 44, "hamburger toggle should be >= 44px, was #{hamburger}"

      avatar = min_dimension("button[aria-haspopup]")
      assert avatar >= 44, "avatar menu trigger should be >= 44px, was #{avatar}"

      toggle_sidebar

      drawer_link = min_dimension("aside[data-sidebar-target='drawer'] a")
      assert drawer_link >= 44, "drawer nav links should be >= 44px tall, was #{drawer_link}"
    end
  end

  context "focus visible (WCAG 2.4.7)" do
    should "ring the avatar menu visibly against the navbar when keyboard-focused" do
      visit root_path
      assert_text "Home"

      focus = page.evaluate_script(<<~JS)
        (() => {
          #{ContrastHelpers::CONTRAST_JS}
          const button = document.querySelector("#user-menu button");
          button.focus();
          const nav = paint([[getComputedStyle(button.closest("nav")).backgroundColor, 1]]);
          const bands = [...getComputedStyle(button).boxShadow.matchAll(/((?:rgba?|oklch|oklab|lab|lch|color)\\([^)]*\\)) 0px 0px 0px ([1-9][0-9.]*)px/g)]
            .map(m => m[1]).filter(c => !/^rgba\\(.*, 0\\)$/.test(c));
          return { focusVisible: button.matches(":focus-visible"), bands: bands,
                   best: Math.max(0, ...bands.map(c => ratio(paint([[c, 1]]), nav))) };
        })()
      JS

      assert focus["focusVisible"], "a script focus with no prior pointer input should read as keyboard focus"
      assert_not_empty focus["bands"], "the avatar trigger draws no focus ring"
      assert_operator focus["best"], :>=, 3, "the ring must stand out from the navbar (1.4.11): #{focus["bands"]}"
    end
  end

  context "brand-coloured text (WCAG 1.4.3)" do
    should "keep the default brand ink at AA on light surfaces, where raw primary fails" do
      visit root_path
      assert_text "Home"

      assert_operator utility_contrast("text-primary", "#ffffff"), :<, 4.5, "raw primary must fail, or this test proves nothing"
      assert_operator utility_contrast("text-primary-ink", "#ffffff"), :>=, 4.5
      assert_operator utility_contrast("text-primary-ink", "#f9fafb"), :>=, 4.5
    end

    should "keep a pale tenant brand at AA as text" do
      @tenant.update!(theme: "custom", custom_theme: { "brand" => { "light" => "#ffd400" } })
      visit root_path
      assert_text "Home"

      assert_operator utility_contrast("text-primary-ink", "#ffffff"), :>=, 4.5
    end

    should "lighten a dark tenant brand to AA in dark mode" do
      @tenant.update!(theme: "custom", custom_theme: { "brand" => { "dark" => "#1e3a8a" } })
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "dark" } ]
      )
      visit root_path
      assert_text "Home"

      assert_operator utility_contrast("text-primary", "#111827"), :<, 4.5, "raw primary must fail, or this test proves nothing"
      assert_operator utility_contrast("text-primary-ink", "#111827"), :>=, 4.5
      assert_operator utility_contrast("text-primary-ink", "#1f2937"), :>=, 4.5
    ensure
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ]
      )
    end
  end

  context "focus outline in dark mode (WCAG 2.4.7)" do
    teardown do
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ]
      )
    end

    should "outline a focused button in the dark colour but leave form fields to the forms plugin" do
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "dark" } ]
      )
      visit root_path
      assert_text "Home"

      outlines = page.evaluate_script(<<~JS)
        (() => {
          const read = (tag, attrs) => {
            const el = document.createElement(tag);
            Object.assign(el, attrs);
            document.querySelector("main").appendChild(el);
            el.focus();
            const style = getComputedStyle(el);
            return { focusVisible: el.matches(":focus-visible"), colour: style.outlineColor };
          };
          return { button: read("button", { textContent: "Probe" }), field: read("input", { type: "text" }) };
        })()
      JS

      assert outlines["button"]["focusVisible"], "a script focus with no prior pointer input should read as keyboard focus"
      assert_equal "rgb(255, 255, 255)", outlines["button"]["colour"], "buttons take the dark focus role"
      assert_equal "rgba(0, 0, 0, 0)", outlines["field"]["colour"], "fields keep the forms plugin's transparent outline"
    end
  end

  context "pointer cursor" do
    should "show the pointer on a plain button and not-allowed once it is disabled" do
      visit root_path
      assert_text "Home"

      cursors = page.evaluate_script(<<~JS)
        (() => {
          const button = document.querySelector("#user-menu button");
          const before = getComputedStyle(button).cursor;
          button.disabled = true;
          const disabled = getComputedStyle(button).cursor;
          button.disabled = false;
          return { before, disabled };
        })()
      JS

      assert_equal "pointer", cursors["before"], "the avatar trigger carries no cursor utility, so the base rule must supply it"
      assert_equal "not-allowed", cursors["disabled"]
    end
  end

  private

  # Smaller of the rendered width/height for the first element matching the
  # CSS selector, in CSS pixels.
  def min_dimension(css)
    page.evaluate_script(<<~JS)
      (() => { const el=document.querySelector(#{css.to_json});
               if(!el) return 0; const r=el.getBoundingClientRect();
               return Math.round(Math.min(r.width, r.height)); })()
    JS
  end
end

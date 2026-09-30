# frozen_string_literal: true

require "application_system_test_case"

# Pins the cross-cutting accessibility affordances baked into the shared
# layout / navbar / sidebar: a document language, a keyboard skip link, and
# touch targets that meet WCAG 2.5.5 (44x44 CSS px). These regressions are
# invisible to the unit suite and only surface in a real browser.
class AccessibilitySystemTest < ApplicationSystemTestCase
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

  context "brand-coloured text (WCAG 1.4.3)" do
    should "keep the default brand ink at AA on light surfaces, where raw primary fails" do
      visit root_path
      assert_text "Home"

      assert_operator text_contrast("text-primary", "#ffffff"), :<, 4.5, "raw primary must fail, or this test proves nothing"
      assert_operator text_contrast("text-primary-ink", "#ffffff"), :>=, 4.5
      assert_operator text_contrast("text-primary-ink", "#f9fafb"), :>=, 4.5
    end

    should "keep a pale tenant brand at AA as text" do
      @tenant.update!(primary_color: "#ffd400")
      visit root_path
      assert_text "Home"

      assert_operator text_contrast("text-primary-ink", "#ffffff"), :>=, 4.5
    end

    should "lighten a dark tenant brand to AA in dark mode" do
      @tenant.update!(primary_color_dark: "#1e3a8a")
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "dark" } ]
      )
      visit root_path
      assert_text "Home"

      assert_operator text_contrast("text-primary", "#111827"), :<, 4.5, "raw primary must fail, or this test proves nothing"
      assert_operator text_contrast("text-primary-ink", "#111827"), :>=, 4.5
      assert_operator text_contrast("text-primary-ink", "#1f2937"), :>=, 4.5
    ensure
      page.driver.browser.execute_cdp(
        "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ]
      )
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

  # WCAG contrast of a probe span carrying +utility+ over +background+, as the
  # browser renders it — tenant overrides and the colour scheme included.
  def text_contrast(utility, background)
    page.evaluate_script(<<~JS, utility, background)
      (() => {
        const probe = document.createElement("span");
        probe.className = arguments[0];
        document.body.appendChild(probe);
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = 1;
        const ctx = canvas.getContext("2d", { willReadFrequently: true });
        const luminance = css => {
          ctx.clearRect(0, 0, 1, 1);
          ctx.fillStyle = css;
          ctx.fillRect(0, 0, 1, 1);
          return [...ctx.getImageData(0, 0, 1, 1).data].slice(0, 3)
            .map(v => v / 255)
            .map(v => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
            .reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
        };
        const [hi, lo] = [luminance(getComputedStyle(probe).color), luminance(arguments[1])].sort((a, b) => b - a);
        probe.remove();
        return Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100;
      })()
    JS
  end
end

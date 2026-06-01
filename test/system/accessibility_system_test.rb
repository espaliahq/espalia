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

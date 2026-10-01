# frozen_string_literal: true

require "application_system_test_case"

class BrandConfettiSystemTest < ApplicationSystemTestCase
  BRAND = "[data-brand-confetti-target='brand']"
  TAGLINE = "#brand-tagline"

  setup do
    @tenant = FactoryBot.create(:tenant, name: "Acme Corp")
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    sign_in_as(@user)
  end

  context "at desktop width" do
    setup do
      visit root_path
      wait_for_stimulus "brand-confetti"
    end

    should "show the tagline on hover and hide it once the pointer leaves the top corner" do
      assert_no_selector "#{TAGLINE}[data-open]", visible: :all

      hover_brand
      assert_selector "#{TAGLINE}[data-open]", text: "not just a tool, but a way of life", visible: :all
      screenshot("tagline_open")

      move_pointer_to(900, 700)
      assert_no_selector "#{TAGLINE}[data-open]", visible: :all
    end

    should "keep the tagline inside the zone under the nav while it follows the pointer" do
      hover_brand
      assert_selector "#{TAGLINE}[data-open]", visible: :all

      move_pointer_to(10, 5)
      nav_bottom = page.evaluate_script("document.querySelector('nav').getBoundingClientRect().bottom")
      tagline_top = page.evaluate_script("document.querySelector('#{TAGLINE}').getBoundingClientRect().top")

      assert_operator tagline_top, :>, nav_bottom, "the tagline should never ride up over the nav"
    end

    should "rain heart hands on click without blocking the page" do
      assert_no_selector "[data-brand-confetti-heart]", visible: :all

      page.execute_script("document.querySelector(\"#{BRAND}\").click()")

      assert_selector "[data-brand-confetti-heart]", minimum: 1, visible: :all
      screenshot("confetti")
      assert_equal "none",
        page.evaluate_script("getComputedStyle(document.querySelector('[data-brand-confetti-layer]')).pointerEvents")
    end

    should "leave neither the tagline nor the confetti in Turbo's page cache" do
      hover_brand
      page.execute_script("document.querySelector(\"#{BRAND}\").click()")
      assert_selector "#{TAGLINE}[data-open]", visible: :all
      assert_selector "[data-brand-confetti-layer][data-turbo-temporary]", visible: :all

      page.execute_script("document.dispatchEvent(new CustomEvent('turbo:before-cache'))")

      assert_no_selector "#{TAGLINE}[data-open]", visible: :all
    end
  end

  context "at mobile width" do
    setup do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit root_path
      wait_for_stimulus "brand-confetti"
    end

    should "keep the tagline on screen" do
      hover_brand
      assert_selector "#{TAGLINE}[data-open]", visible: :all
      screenshot("tagline_open_mobile")

      right = page.evaluate_script("document.querySelector('#{TAGLINE}').getBoundingClientRect().right")
      assert_operator right, :<=, page.evaluate_script("window.innerWidth")
    end
  end

  private

  # Pointer events are dispatched rather than driven through Selenium, whose
  # synthetic hover is dropped on a starved CI runner (testing.md).
  def hover_brand
    page.execute_script(<<~JS)
      const brand = document.querySelector("#{BRAND}")
      const rect = brand.getBoundingClientRect()
      brand.dispatchEvent(new MouseEvent("mouseenter", {
        clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2
      }))
    JS
  end

  def move_pointer_to(x, y)
    page.execute_script(<<~JS)
      window.dispatchEvent(new MouseEvent("mousemove", { clientX: #{x}, clientY: #{y} }))
    JS
  end
end

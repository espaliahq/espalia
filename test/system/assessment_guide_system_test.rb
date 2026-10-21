# frozen_string_literal: true

require "application_system_test_case"

class AssessmentGuideSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    sign_in_as(@user)
  end

  # The top edge of each of the four step links, in order.
  def station_tops
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("nav[aria-label='The four steps'] li"))
        .map((li) => Math.round(li.getBoundingClientRect().top))
    JS
  end

  context "the way in" do
    should "open the guide from My Assessments" do
      visit assessments_path
      assert_text "My Assessments"

      click_link_with_js_fallback "How assessments work →", expect_text: "One cycle. Four steps."

      assert_current_path assessment_guide_path
    end

    should "keep the link on screen on a phone" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessments_path
      assert_text "My Assessments"

      assert_selector "a[href='#{assessment_guide_path}']", text: "How assessments work →", visible: true
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, MOBILE_SIZE.first
    end
  end

  context "the guide" do
    should "lay the four steps out in one row on desktop" do
      visit assessment_guide_path
      assert_text "One cycle. Four steps."

      tops = station_tops
      assert_equal 4, tops.size
      assert_equal 1, tops.uniq.size, "expected the four steps side by side, got tops #{tops}"
    end

    should "stack the four steps on a phone without scrolling sideways" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_guide_path
      assert_text "One cycle. Four steps."

      tops = station_tops
      assert_equal tops.sort, tops
      assert_equal 4, tops.uniq.size, "expected the four steps stacked, got tops #{tops}"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, MOBILE_SIZE.first

      # Each header's text on one line, inside its own cell.
      misfits = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll("[data-guide-level-header]")).filter((cell) => {
          const range = document.createRange()
          range.selectNodeContents(cell)
          const text = range.getBoundingClientRect()
          const box = cell.getBoundingClientRect()
          const lines = new Set(Array.from(range.getClientRects()).map((r) => Math.round(r.top))).size
          return lines > 1 || text.left < box.left - 1 || text.right > box.right + 1
        }).map((cell) => cell.textContent)
      JS
      assert_empty misfits, "level headers no longer fit their columns"
    end

    should "jump to a step from the step list" do
      visit assessment_guide_path
      assert_text "One cycle. Four steps."

      click_selector_with_js_fallback "nav[aria-label='The four steps'] a[href='#align']",
        expect_selector: "section#align:target"

      assert_selector "section#align:target h2", text: "Sit down together and agree what's true"
      assert_operator page.evaluate_script("document.getElementById('align').getBoundingClientRect().top"), :<, 200
    end
  end
end

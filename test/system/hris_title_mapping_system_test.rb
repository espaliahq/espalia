# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/hris_mapping_fixtures"

# Mapping HRIS titles from the integrations page (#436).
class HrisTitleMappingSystemTest < ApplicationSystemTestCase
  include HrisMappingFixtures

  MODAL = "##{Views::Integrations::HrisMappingModal::ID}".freeze
  MAP_RENAMED = "button[aria-label='Map Engineering Manager (EM3) to a role']"

  setup { build_hris_mapping_tenant }

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
        visit tenant_integration_path("hris")
        assert_text "Unmapped titles"
        wait_for_stimulus "hris-mapping-form"
      end

      should "map a renamed title and say who the next sync moves" do
        assert_text "Vera Renamed is still on E L3 from an earlier title"
        assert_no_page_overflow
        assert_on_screen find(MAP_RENAMED)
        screenshot("unmapped_titles_#{viewport}")

        click_selector_with_js_fallback(MAP_RENAMED, expect_selector: "#{MODAL}.flex")
        title = find("#hris-mapping-title")
        assert_equal "Engineering Manager (EM3)", title.value
        assert title.readonly?, "an existing title is moved, not renamed"

        select "Engineering Manager (EM)", from: "Framework role"
        assert_selector "#hris-mapping-level option[value='2'][disabled]", visible: :all
        assert_selector "#hris-mapping-level option[value='4']:not([disabled])", visible: :all
        screenshot("mapping_modal_#{viewport}")

        click_button_with_js_fallback("Save mapping",
          expect_text: "The next sync moves Vera Renamed from E L3 to EM L3.")
        assert_no_selector "tr[data-unmapped-title='Engineering Manager (EM3)']"
        assert_selector "[data-mapped-title='Engineering Manager (EM3)']"
        screenshot("mapped_#{viewport}")
      end
    end
  end

  context "at desktop" do
    setup do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      sign_in_as(@admin_user)
      visit tenant_integration_path("hris")
      assert_text "Role Mappings"
      wait_for_stimulus "hris-mapping-form"
    end

    should "remove a mapped title and list it as unmapped" do
      click_selector_with_js_fallback("button[aria-label='Remove mapping for Software Engineer']",
        expect_text: "Removed “Software Engineer”")

      assert_selector "tr[data-unmapped-title='Software Engineer']", text: "Sam Settled is still on E L3"
    end

    should "add a mapping for a title typed by hand, at a fixed level" do
      click_button_with_js_fallback("Add mapping", expect_selector: "#{MODAL}.flex")
      assert_not find("#hris-mapping-title").readonly?

      js_fill_in "HRIS job title", with: "Analytics Lead"
      select "Analytics Engineer (AE)", from: "Framework role"
      select "Everyone at L3", from: "Level"
      click_button_with_js_fallback("Save mapping",
        expect_text: "The next sync moves Kit Unmapped from AE L2 to AE L3.")

      assert_selector "[data-mapped-title='Analytics Lead']"
    end
  end

  private

  # A table scrolls inside its own card; the page itself never scrolls sideways.
  def assert_no_page_overflow
    widths = page.evaluate_script("[document.documentElement.scrollWidth, document.documentElement.clientWidth]")
    assert_operator widths[0], :<=, widths[1], "the page scrolls sideways (scrollWidth #{widths[0]} > #{widths[1]})"
  end

  def assert_on_screen(element)
    right = page.evaluate_script("arguments[0].getBoundingClientRect().right", element)
    assert_operator right, :<=, page.evaluate_script("document.documentElement.clientWidth")
  end
end

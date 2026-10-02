# frozen_string_literal: true

require "application_system_test_case"

class Tenant::FeedbackExportSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person, tenant: @tenant, email: @admin_user.email, name: "Ada Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)

      framework_id = SecureRandom.uuid_v7
      @current = FactoryBot.create(:assessment_cycle,
        tenant: @tenant, name: "Q3 2026", framework_id: framework_id, opened_at: 5.days.ago)
      @previous = FactoryBot.create(:assessment_cycle, :closed,
        tenant: @tenant, name: "Q1 2026", framework_id: framework_id,
        opened_at: Time.zone.parse("2026-01-05"), closed_at: Time.zone.parse("2026-03-20"))
    end

    sign_in_as(@admin_user)
  end

  should "reach the export from the sidebar and pick a cycle on desktop" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit tenant_root_path
    assert_text "Tenant administration"

    click_selector_with_js_fallback "aside nav a[href='#{new_tenant_feedback_export_path}']",
      expect_text: "Download Q3 2026"

    assert_current_path new_tenant_feedback_export_path
    assert_selector "aside nav a[aria-current='page']", text: "Feedback export"
    assert_download_form_for(@current)
    screenshot("picker_desktop")

    select "Q1 2026 (closed)", from: "Assessment cycle"
    click_button_with_js_fallback "Choose cycle", expect_text: "Download Q1 2026"

    assert_download_form_for(@previous)
    assert_selector "select#feedback-export-month option", text: "February 2026"
    assert_no_selector "select#feedback-export-month option", text: "April 2026"
  end

  should "show the picker in the tenant admin layout on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    visit new_tenant_feedback_export_path

    assert_text "Download Q3 2026"
    assert_selector "aside nav a[aria-current='page']", text: "Feedback export"
    assert_download_form_for(@current)
    assert_selector "button", text: "Download CSV", visible: true
    assert_no_horizontal_page_scroll
    screenshot("picker_mobile")
  end

  private

  def assert_download_form_for(cycle)
    form = find("form#feedback-export-download")
    assert_equal tenant_feedback_exports_path(format: :csv), URI(form[:action]).path
    assert_equal "false", form["data-turbo"]
    assert_equal cycle.cycle_id, form.find("input[name=cycle_id]", visible: :all).value
    assert form.has_field?("Include withdrawn feedback", type: "checkbox")
    assert form.has_select?("Month", with_options: [ "Whole cycle" ])
  end

  def assert_no_horizontal_page_scroll
    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    assert_operator overflow, :<=, 0
  end
end

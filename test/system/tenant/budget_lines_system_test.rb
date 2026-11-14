# frozen_string_literal: true

require "application_system_test_case"

# The approved budget screen (Team Planning 6.1), at both widths. Fixture figures only.
class Tenant::BudgetLinesSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user)
    @planner_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person, tenant: @tenant, name: "Ada Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @planner_user, role: :member, team_planner: true)
      role = FactoryBot.create(:framework_role, tenant: @tenant, name: "Software Engineer")
      @level = FactoryBot.create(:framework_level, tenant: @tenant, role_id: role.role_id, code: "E2", title: "Engineer II")
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "add a line, change it and remove it" do
        visit tenant_budget_lines_path
        assert_text "No budget lines yet"

        js_fill_in "#budget-line-starts-on", with: "2027-01-01"
        js_fill_in "#budget-line-ends-on", with: "2027-12-31"
        js_fill_in "#budget-line-approved-on", with: "2026-10-01"
        js_fill_in "#budget-line-amount", with: "120,000"
        js_fill_in "#budget-line-currency", with: "AUD"
        js_fill_in "#budget-line-head-count", with: "2"
        select "E2 Engineer II", from: "Role and level"
        js_fill_in "#budget-line-location", with: "Fixtureland"
        click_button_with_js_fallback("budget-line-add", expect_text: "Budget line added for Software Engineer, E2 Engineer II.")

        line = ActsAsTenant.with_tenant(@tenant) { BudgetLine.sole }
        within("#budget-line-#{line.id}") do
          assert_text "AUD 120,000 a year · Head count 2"
          assert_text "New position, approved 1 Oct 2026 · 1 Jan 2027 to 31 Dec 2027 · Fixtureland"
          assert_text "Changed by Ada Admin"
        end
        assert_no_sideways_overflow
        assert_no_stolen_taps
        screenshot("listed_#{viewport}")

        click_link_with_js_fallback("budget-line-change-#{line.id}", expect_text: "Change a budget line")
        js_fill_in "#budget-line-amount", with: ""
        select "Replacement", from: "Origin"
        assert_no_sideways_overflow
        screenshot("edit_#{viewport}")
        click_button_with_js_fallback("budget-line-save", expect_text: "Budget line changed for")
        within("#budget-line-#{line.id}") do
          assert_text "No amount · Head count 2"
          assert_text "Replacement · 1 Jan 2027 to 31 Dec 2027"
        end

        open_dropdown(scope: "#budget-line-#{line.id}")
        page.execute_script("document.getElementById('budget-line-remove-item-#{line.id}').click()")
        assert_selector "#budget-line-remove-confirm-#{line.id}", visible: true
        screenshot("remove_#{viewport}")
        click_button_with_js_fallback("budget-line-remove-confirm-#{line.id}", expect_text: "Budget line removed for")
        assert_text "No budget lines yet"
      end

      should "show a refused line again with what was typed" do
        visit tenant_budget_lines_path
        assert_text "No budget lines yet"

        js_fill_in "#budget-line-starts-on", with: "2027-06-01"
        js_fill_in "#budget-line-ends-on", with: "2027-05-31"
        js_fill_in "#budget-line-amount", with: "50000"
        js_fill_in "#budget-line-currency", with: "AUD"
        click_button_with_js_fallback("budget-line-add", expect_text: "The budget line could not be added")

        assert_text "A budget line can't end before it starts"
        assert_field "Amount", with: "50000"
        assert_no_sideways_overflow
        screenshot("refused_#{viewport}")
      end
    end
  end

  should "keep the screen from a planner who isn't an admin" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@planner_user)

    visit tenant_budget_lines_path
    assert_text "You are not authorized to perform this action."
    assert_no_text "Add a line"
  end
end

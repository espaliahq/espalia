# frozen_string_literal: true

require "application_system_test_case"

# The planning inputs history, reached from the pay bands screen, at both widths. Fixture figures only.
class Tenant::PlanningInputsHistorySystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person, tenant: @tenant, name: "Ada Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)
      role = FactoryBot.create(:framework_role, tenant: @tenant)
      level = FactoryBot.create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, code: "E2", title: "Engineer II")
      band = add_pay_band!(level:, location: "Fixtureland", currency: "AUD", period: "year",
                           minimum: 100_000, midpoint: 120_000, maximum: 140_000, changed_by_id: admin.id)
      26.times do |index|
        band.midpoint = 120_001 + index
        save_planning_input!(:pay_bands, band, changed_by_id: admin.id)
      end
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport} width" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "open the band history from the pay bands screen and page back to the band's first change" do
        visit tenant_pay_bands_path
        assert_selector "h1", text: "Pay bands"

        click_link_with_js_fallback("Band history", expect_text: "Pay band history")
        assert_selector "#planning-inputs-history li", count: 25
        assert_text "After: AUD 100,000 to 140,000 a year · Midpoint 120,026"
        assert_no_sideways_overflow

        click_link_with_js_fallback("Older", expect_text: "Added the band for")
        assert_selector "#planning-inputs-history li", count: 2
        assert_link "Newer"
        assert_no_link "Older"
        assert_no_sideways_overflow
      end

      should "show the reference currency before and after it changes in the rate history" do
        ActsAsTenant.with_tenant(@tenant) do
          currency = add_planning_input!(:reference_currencies, currency: "AUD")
          currency.currency = "USD"
          save_planning_input!(:reference_currencies, currency)
        end

        visit tenant_pay_bands_path
        click_link_with_js_fallback("Rate history", expect_text: "Set the reference currency to USD")

        within "#planning-inputs-history li:first-child" do
          assert_text "Before: AUD"
          assert_text "After: USD"
        end
        within "#planning-inputs-history li:last-child" do
          assert_text "Set the reference currency to AUD"
          assert_no_text "Before:"
        end
        assert_no_sideways_overflow
      end
    end
  end
end

# frozen_string_literal: true

require "application_system_test_case"

# The exchange rates panel beside the pay bands (Team Planning 5.3), at both widths. Fixture rates only.
class Tenant::ExchangeRatesSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person, tenant: @tenant, name: "Ada Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "set the reference currency, then add a rate, change it and remove it" do
        visit tenant_pay_bands_path
        within("#exchange-rates") { assert_text "No rates yet." }

        js_fill_in "#reference-currency", with: "AUD"
        click_button_with_js_fallback("reference-currency-save", expect_text: "Reports now total in AUD.")
        assert_field "exchange-rate-to", with: "AUD"

        js_fill_in "#exchange-rate-from", with: "NZD"
        js_fill_in "#exchange-rate-rate", with: "0.92"
        js_fill_in "#exchange-rate-applies-from", with: "2026-07-01"
        click_button_with_js_fallback("exchange-rate-add", expect_text: "Rate added for NZD to AUD from 1 Jul 2026.")

        rate = ActsAsTenant.with_tenant(@tenant) { ExchangeRate.sole }
        within("#exchange-rate-#{rate.id}") do
          assert_text "1 NZD = 0.92 AUD · from 1 Jul 2026"
          assert_text "Changed by Ada Admin"
        end
        assert_no_sideways_overflow
        assert_no_stolen_taps
        screenshot("listed_#{viewport}")

        click_link_with_js_fallback("exchange-rate-change-#{rate.id}", expect_text: "Change an exchange rate")
        js_fill_in "#exchange-rate-rate", with: "0.95"
        assert_no_sideways_overflow
        screenshot("edit_#{viewport}")
        click_button_with_js_fallback("exchange-rate-save", expect_text: "Rate changed for NZD to AUD")
        within("#exchange-rate-#{rate.id}") { assert_text "1 NZD = 0.95 AUD" }

        open_dropdown(scope: "#exchange-rate-#{rate.id}")
        page.execute_script("document.getElementById('exchange-rate-remove-item-#{rate.id}').click()")
        assert_selector "#exchange-rate-remove-confirm-#{rate.id}", visible: true
        screenshot("remove_#{viewport}")
        click_button_with_js_fallback("exchange-rate-remove-confirm-#{rate.id}", expect_text: "Rate removed for")
        within("#exchange-rates") { assert_text "No rates yet." }
      end

      should "show a refused rate again with what was typed" do
        visit tenant_pay_bands_path
        within("#exchange-rates") { assert_text "No rates yet." }

        js_fill_in "#exchange-rate-from", with: "NZD"
        js_fill_in "#exchange-rate-to", with: "NZD"
        js_fill_in "#exchange-rate-rate", with: "1.5"
        js_fill_in "#exchange-rate-applies-from", with: "2026-07-01"
        click_button_with_js_fallback("exchange-rate-add", expect_text: "The rate could not be added")

        assert_field "exchange-rate-rate", with: "1.5"
        assert_no_sideways_overflow
        screenshot("refused_#{viewport}")
      end
    end
  end
end

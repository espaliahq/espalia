# frozen_string_literal: true

require "application_system_test_case"

# The pay bands screen (Team Planning 5.1), at both widths. Fixture figures only.
class Tenant::PayBandsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user)
    @member_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person, tenant: @tenant, name: "Ada Admin")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      role = FactoryBot.create(:framework_role, tenant: @tenant)
      @level = FactoryBot.create(:framework_level, tenant: @tenant, role_id: role.role_id, code: "E2", title: "Engineer II")
    end
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "add a band, change it and remove it" do
        visit tenant_pay_bands_path
        assert_text "No pay bands yet"

        select "E2 Engineer II", from: "Level"
        js_fill_in "#pay-band-location", with: "Fixtureland"
        js_fill_in "#pay-band-currency", with: "AUD"
        js_fill_in "#pay-band-minimum", with: "100,000"
        js_fill_in "#pay-band-midpoint", with: "120,000"
        js_fill_in "#pay-band-maximum", with: "140,000"
        click_button_with_js_fallback("pay-band-add", expect_text: "Band added for Software Engineer, E2 Engineer II, Fixtureland.")

        band = ActsAsTenant.with_tenant(@tenant) { PayBand.sole }
        within("#pay-band-#{band.id}") do
          assert_text "AUD 100,000 to 140,000 a year. Midpoint 120,000."
          assert_text "Changed by Ada Admin"
        end
        assert_no_sideways_overflow
        assert_no_stolen_taps
        screenshot("listed_#{viewport}")

        click_link_with_js_fallback("pay-band-change-#{band.id}", expect_text: "Change a pay band")
        js_fill_in "#pay-band-maximum", with: "150000"
        select "A month", from: "Paid per"
        assert_no_sideways_overflow
        screenshot("edit_#{viewport}")
        click_button_with_js_fallback("pay-band-save", expect_text: "Band changed for")
        within("#pay-band-#{band.id}") { assert_text "AUD 100,000 to 150,000 a month." }

        open_dropdown(scope: "#pay-band-#{band.id}")
        page.execute_script("document.getElementById('pay-band-remove-item-#{band.id}').click()")
        assert_selector "#pay-band-remove-confirm-#{band.id}", visible: true
        screenshot("remove_#{viewport}")
        click_button_with_js_fallback("pay-band-remove-confirm-#{band.id}", expect_text: "Band removed for")
        assert_text "No pay bands yet"
      end

      should "show a refused band again with what was typed" do
        visit tenant_pay_bands_path
        assert_text "No pay bands yet"

        select "E2 Engineer II", from: "Level"
        js_fill_in "#pay-band-currency", with: "AUD"
        js_fill_in "#pay-band-minimum", with: "130000"
        js_fill_in "#pay-band-midpoint", with: "120000"
        js_fill_in "#pay-band-maximum", with: "140000"
        click_button_with_js_fallback("pay-band-add", expect_text: "The band could not be added")

        assert_field "Minimum", with: "130000"
        assert_select "Level", selected: "E2 Engineer II"
        assert_no_sideways_overflow
        screenshot("refused_#{viewport}")
      end
    end
  end

  should "keep the screen and its menu link from members" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@member_user)

    visit tenant_pay_bands_path
    assert_text "You are not authorized to perform this action."
    assert_no_text "Add a band"
  end
end

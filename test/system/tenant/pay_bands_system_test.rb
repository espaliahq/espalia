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
      @family = FactoryBot.create(:framework_role_family, tenant: @tenant, name: "Engineering")
      @role = FactoryBot.create(:framework_role, tenant: @tenant, role_family_id: @family.role_family_id)
      @level = FactoryBot.create(:framework_level, tenant: @tenant, role_id: @role.role_id, ordinal: 2,
                                                   code: "E2", title: "Engineer II")
    end
  end

  def store_band(location, **match)
    ActsAsTenant.with_tenant(@tenant) do
      PayBand.new(location:, currency: "AUD", period: "year", minimum: 100_000, midpoint: 120_000, maximum: 140_000)
             .tap { it.match_on(**match) }.tap(&:save!)
    end
  end

  def locations_in_order = ActsAsTenant.with_tenant(@tenant) { PayBand.order(:position).pluck(:location) }

  # Selenium can't drive an HTML drag, so this sends the events a drag sends.
  # A drag's events all target the row; `grab` is where the pointer went down.
  def drag_below(source, target, cancel: false, grab: source)
    page.execute_script(<<~JS, source, target, cancel, grab)
      const [source, target, cancel, grab] = arguments
      const dataTransfer = new DataTransfer()
      const fire = (element, type, clientY) =>
        element.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer, clientY }))
      const { bottom } = target.getBoundingClientRect()
      grab.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true }))
      fire(source, "dragstart", 0)
      fire(target, "dragover", bottom - 1)
      if (!cancel) fire(target, "drop", bottom - 1)
      fire(source, "dragend", 0)
    JS
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

        select "Software Engineer", from: "Who"
        select "Level 2", from: "Level"
        js_fill_in "#pay-band-location", with: "Fixtureland"
        js_fill_in "#pay-band-currency", with: "AUD"
        js_fill_in "#pay-band-minimum", with: "100,000"
        js_fill_in "#pay-band-midpoint", with: "120,000"
        js_fill_in "#pay-band-maximum", with: "140,000"
        click_button_with_js_fallback("pay-band-add", expect_text: "Band added for Software Engineer, E2 Engineer II, Fixtureland at 1 in the list.")

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

        select "Every role in Engineering", from: "Who"
        js_fill_in "#pay-band-currency", with: "AUD"
        js_fill_in "#pay-band-minimum", with: "130000"
        js_fill_in "#pay-band-midpoint", with: "120000"
        js_fill_in "#pay-band-maximum", with: "140000"
        click_button_with_js_fallback("pay-band-add", expect_text: "The band could not be added")

        assert_field "Minimum", with: "130000"
        assert_select "Who", selected: "Every role in Engineering"
        assert_select "Level", selected: "Every level"
        assert_no_sideways_overflow
        screenshot("refused_#{viewport}")
      end

      should "move a band with its buttons, and flag one that never has the last word" do
        narrow = store_band("Fixtureland", role: @role, level_ordinal: 2)
        wide = store_band("Fixtureland", role_family: @family)
        visit tenant_pay_bands_path
        assert_text "The order"
        assert_no_selector "[id^='pay-band-shadowed-']"

        click_button_with_js_fallback("pay-band-down-#{wide.id}", expect_text: "to 2 in the list")
        assert_equal [ narrow.id, wide.id ], ActsAsTenant.with_tenant(@tenant) { PayBand.order(:position).ids }
        within("#pay-band-#{narrow.id}") do
          assert_text "1."
          assert_selector "#pay-band-shadowed-#{narrow.id}", text: "Never used"
          assert_text "A band below it matches every seat this one does"
        end
        assert_no_sideways_overflow
        assert_no_stolen_taps
        screenshot("shadowed_#{viewport}")

        click_button_with_js_fallback("pay-band-up-#{wide.id}", expect_text: "to 1 in the list")
        assert_no_selector "[id^='pay-band-shadowed-']"
      end
    end
  end

  should "drag a band into a new place on a desktop" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@admin_user)
    first = store_band("Alpha")
    store_band("Beta")
    store_band("Gamma")
    visit tenant_pay_bands_path
    assert_text "The order"
    wait_for_stimulus "pay-band-order"

    drag_below(find("#pay-band-#{first.id}"), find("#pay-bands-order li:last-child"))

    assert_text "Saved the new order."
    assert_equal %w[Beta Gamma Alpha], locations_in_order
    assert_selector "#pay-bands-order li:last-child", text: "3."
  end

  should "put the rows back and save nothing when a drag is cancelled" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@admin_user)
    first = store_band("Alpha")
    store_band("Beta")
    visit tenant_pay_bands_path
    assert_text "The order"
    wait_for_stimulus "pay-band-order"

    drag_below(find("#pay-band-#{first.id}"), find("#pay-bands-order li:last-child"), cancel: true)

    assert_selector "#pay-bands-order li:first-child#pay-band-#{first.id}"
    assert_no_text "Saved the new order."
    assert_equal %w[Alpha Beta], locations_in_order
  end

  should "leave a row in place when the drag starts on one of its buttons" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@admin_user)
    first = store_band("Alpha")
    store_band("Beta")
    visit tenant_pay_bands_path
    assert_text "The order"
    wait_for_stimulus "pay-band-order"

    drag_below(find("#pay-band-#{first.id}"), find("#pay-bands-order li:last-child"), grab: find("#pay-band-down-#{first.id}"))

    assert_selector "#pay-bands-order li:first-child#pay-band-#{first.id}"
    assert_no_text "Saved the new order."
    assert_equal %w[Alpha Beta], locations_in_order
  end

  should "keep the screen and its menu link from members" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@member_user)

    visit tenant_pay_bands_path
    assert_text "You are not authorized to perform this action."
    assert_no_text "Add a band"
  end
end

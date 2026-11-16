# frozen_string_literal: true

require "application_system_test_case"

# The cost-centre entries screen (#387), at both widths. Fixture units and labels only.
class Tenant::CostCentreRulesSystemTest < ApplicationSystemTestCase
  include OrgGraphFixture

  setup do
    @tenant = FactoryBot.create(:tenant)
    @org = build_org_graph(@tenant)
    @admin_user = FactoryBot.create(:user)
    @member_user = FactoryBot.create(:user)
    ActsAsTenant.with_tenant(@tenant) do
      admin = FactoryBot.create(:person, tenant: @tenant, name: "Ada Admin")
      @admin = FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, person: admin, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      @family = FactoryBot.create(:framework_role_family, tenant: @tenant, name: "Engineering")
      role = FactoryBot.create(:framework_role, tenant: @tenant, role_family_id: @family.role_family_id)
      FactoryBot.create(:framework_level, tenant: @tenant, role_id: role.role_id, ordinal: 2, code: "E2", title: "Engineer II")
    end
  end

  def store_entries(*entries)
    ActsAsTenant.with_tenant(@tenant) do
      context = AuthorizationContext.new(user: @admin_user, tenant_user: @admin, person: @admin.person)
      Operations::Tenants::SetPlanningRule.call(context:, params: { rule: "cost_centre", value: { "entries" => entries } })
    end
  end

  def labels_in_order
    ActsAsTenant.with_tenant(@tenant) { PlanningRuleDefault.find_by(rule: "cost_centre").value["entries"].pluck("cost_centre") }
  end

  def located(*labels) = labels.map { { "location" => it, "cost_centre" => it } }

  # Selenium can't drive an HTML drag, so this sends the events a drag sends.
  def drag_below(source, target)
    page.execute_script(<<~JS, source, target)
      const [source, target] = arguments
      const dataTransfer = new DataTransfer()
      const fire = (element, type, clientY) =>
        element.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer, clientY }))
      const { bottom } = target.getBoundingClientRect()
      source.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, cancelable: true }))
      fire(source, "dragstart", 0)
      fire(target, "dragover", bottom - 1)
      fire(target, "drop", bottom - 1)
      fire(source, "dragend", 0)
    JS
  end

  { "desktop" => DESKTOP_SIZE, "mobile" => MOBILE_SIZE }.each do |viewport, size|
    context "at #{viewport}" do
      setup do
        page.driver.browser.manage.window.resize_to(*size)
        sign_in_as(@admin_user)
      end

      should "add an entry, change it and remove it" do
        visit tenant_cost_centre_rules_path
        assert_text "No cost-centre entries yet"

        select "Checkout", from: "Unit"
        select "Every role in Engineering", from: "Who"
        js_fill_in "#cost-centre-entry-label", with: "CC Checkout"
        click_button_with_js_fallback("cost-centre-entry-add", expect_text: "Entry added for CC Checkout at 1 in the list.")

        within("#cost-centre-entry-1") { assert_text "Checkout and below · Every role in Engineering" }
        assert_no_sideways_overflow
        assert_no_stolen_taps
        screenshot("listed_#{viewport}")

        click_link_with_js_fallback("cost-centre-entry-change-1", expect_text: "Change a cost-centre entry")
        select "Payments", from: "Unit"
        select "Level 2", from: "Level"
        assert_no_sideways_overflow
        screenshot("edit_#{viewport}")
        click_button_with_js_fallback("cost-centre-entry-save", expect_text: "Entry 1 changed.")
        within("#cost-centre-entry-1") { assert_text "Payments and below · Every role in Engineering · Level 2" }

        open_dropdown(scope: "#cost-centre-entry-1")
        page.execute_script("document.getElementById('cost-centre-entry-remove-item-1').click()")
        assert_selector "#cost-centre-entry-remove-confirm-1", visible: true
        screenshot("remove_#{viewport}")
        click_button_with_js_fallback("cost-centre-entry-remove-confirm-1", expect_text: "Entry 1 removed.")
        assert_text "No cost-centre entries yet"
      end

      should "move an entry with its buttons, and flag one a later entry always overrides" do
        store_entries({ "unit_id" => @org[:checkout], "cost_centre" => "Checkout" }, { "unit_id" => @org[:payments], "cost_centre" => "Payments" })
        visit tenant_cost_centre_rules_path
        assert_text "The order"
        assert_no_selector "[id^='cost-centre-entry-shadowed-']"

        click_button_with_js_fallback("cost-centre-entry-down-1", expect_text: "Moved the entry for Checkout to 2 in the list.")
        assert_equal %w[Payments Checkout], labels_in_order
        within("#cost-centre-entry-1") do
          assert_selector "#cost-centre-entry-shadowed-1", text: "Never used"
          assert_text "An entry below it matches every seat this one does"
        end
        assert_no_sideways_overflow
        assert_no_stolen_taps
        screenshot("shadowed_#{viewport}")

        click_button_with_js_fallback("cost-centre-entry-up-2", expect_text: "Moved the entry for Checkout to 1 in the list.")
        assert_no_selector "[id^='cost-centre-entry-shadowed-']"
      end

      should "save nothing from a page another admin has changed since" do
        store_entries(*located("Alpha", "Beta"))
        visit tenant_cost_centre_rules_path
        assert_text "The order"

        store_entries(*located("Alpha", "Beta", "Gamma"))
        click_button_with_js_fallback("cost-centre-entry-down-1", expect_text: "The list changed since you opened it")

        assert_selector "#cost-centre-entry-3", text: "Gamma"
        assert_equal %w[Alpha Beta Gamma], labels_in_order
      end
    end
  end

  should "drag an entry into a new place on a desktop" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@admin_user)
    store_entries(*located("Alpha", "Beta", "Gamma"))
    visit tenant_cost_centre_rules_path
    assert_text "The order"
    wait_for_stimulus "drag-order"

    drag_below(find("#cost-centre-entry-1"), find("#cost-centre-entries li:last-child"))

    assert_text "Saved the new order."
    assert_equal %w[Beta Gamma Alpha], labels_in_order
  end

  should "keep the screen from members" do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@member_user)

    visit tenant_cost_centre_rules_path
    assert_text "You are not authorized to perform this action."
    assert_no_text "Add an entry"
  end
end

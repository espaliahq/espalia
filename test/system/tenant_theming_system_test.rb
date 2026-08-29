# frozen_string_literal: true

require "application_system_test_case"

class TenantThemingSystemTest < ApplicationSystemTestCase
  setup do
    @tenant_a = FactoryBot.create(:tenant, name: "Teal Corp", primary_color: "#32c8c8", secondary_color: "#079191")
    @tenant_b = FactoryBot.create(:tenant, name: "Indigo Inc", primary_color: "#6366f1", secondary_color: "#4f46e5")
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant_a) { FactoryBot.create(:tenant_user, tenant: @tenant_a, user: @user) }
    ActsAsTenant.with_tenant(@tenant_b) { FactoryBot.create(:tenant_user, tenant: @tenant_b, user: @user) }

    sign_in_as(@user)
  end

  context "tenant theming" do
    should "inject CSS variables for current tenant via style tag" do
      visit root_path
      screenshot("first_tenant_theme")

      theme_style = evaluate_script("document.getElementById('tenant-theme')?.textContent || ''")
      # First auto-selected tenant's colours should be present
      assert_match(/--color-primary/, theme_style)
      assert_match(/--color-secondary/, theme_style)
    end

    should "change CSS variables after switching tenant" do
      visit root_path
      initial_style = evaluate_script("document.getElementById('tenant-theme')?.textContent || ''")
      screenshot("before_switch")

      # Find the tenant-switch form directly by its action URL — bypasses any
      # dropdown visibility race and pointer-click dropouts on starved CI.
      # The form is in the DOM from server render (non-current tenants only,
      # so with two tenants it's unambiguous); opening the dropdown only
      # toggles its visibility, not its presence. Assert presence first — a
      # silent `form?.` no-op turned any drift into a baffling
      # style-unchanged failure on CI.
      switch_selector = "form[action='#{users_tenant_switch_path}']"
      assert_selector switch_selector, visible: :all, count: 1

      # The retry must target tenant B's form SPECIFICALLY: after a successful
      # switch the re-rendered page's only form points back to tenant A, so a
      # blind resubmit would undo a slow-but-successful switch. Targeting B
      # makes the retry a no-op once switched (the ?. chain finds no form) and
      # only refires when the first submit was genuinely dropped.
      submit_switch_to_b = lambda do
        page.execute_script(<<~JS)
          const form = [...document.querySelectorAll(#{switch_selector.inspect})]
            .find(f => f.querySelector("input[name='tenant_id']")?.value === #{@tenant_b.id.to_json});
          form?.requestSubmit();
        JS
      end
      submit_switch_to_b.call
      screenshot("after_switch")

      # The switch is a Turbo form POST that re-renders the page with new
      # theme variables. On a starved runner the fetch itself has been
      # observed to drop — re-submit (B-targeted, so undo-safe) if the style
      # hasn't changed.
      # Wait for tenant B's colour to be PRESENT, not for tenant A's style to be
      # absent: Turbo replaces the <style> tag on re-render, and during that gap
      # the element is missing entirely — which satisfied an absence check on a
      # render that had switched nothing, and the old value then came back.
      switched_xpath =
        "//style[@id='tenant-theme'][contains(text(), #{@tenant_b.primary_color.inspect})]"
      submit_switch_to_b.call unless page.has_xpath?(switched_xpath, visible: :all, wait: 8)

      assert page.has_xpath?(
        switched_xpath,
        # visible: :all is load-bearing — a <style> tag is never "visible", so
        # without it these matchers answer instantly regardless of the DOM and
        # the wait they exist to provide never happens.
        visible: :all,
        wait: Capybara.default_max_wait_time
      ), "CSS variables should change after tenant switch"

      new_style = evaluate_script("document.getElementById('tenant-theme')?.textContent || ''")
      assert_not_equal initial_style, new_style, "CSS variables should change after tenant switch"
    end
  end
end

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

      # Open menu and find which tenant is NOT current, then switch to it
      open_dropdown

      # Click whichever tenant is a button (not the current one which is a div).
      # Submit the form via requestSubmit — Capybara's pointer click on the
      # submit button has been observed dropped on starved CI runners.
      page.execute_script(<<~JS)
        const menu = document.querySelector("[role='menu']");
        const btn = menu?.querySelector("button[type='submit']");
        btn?.closest("form")?.requestSubmit(btn);
      JS
      screenshot("after_switch")

      # The tenant switch is a form POST that re-renders the page with new
      # theme variables. Read the style only after Capybara has waited for
      # the new DOM to commit — has_no_xpath? polls within Capybara's wait.
      assert page.has_no_xpath?(
        "//style[@id='tenant-theme'][text()=#{initial_style.inspect}]",
        wait: Capybara.default_max_wait_time
      ), "CSS variables should change after tenant switch"

      new_style = evaluate_script("document.getElementById('tenant-theme')?.textContent || ''")
      assert_not_equal initial_style, new_style, "CSS variables should change after tenant switch"
    end
  end
end

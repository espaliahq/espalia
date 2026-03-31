# frozen_string_literal: true

require "application_system_test_case"

class TenantThemingSystemTest < ApplicationSystemTestCase
  setup do
    @tenant_a = FactoryBot.create(:tenant, name: "Teal Corp", primary_color: "#32c8c8", secondary_color: "#079191")
    @tenant_b = FactoryBot.create(:tenant, name: "Indigo Inc", primary_color: "#6366f1", secondary_color: "#4f46e5")
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant_a) { FactoryBot.create(:tenant_user, tenant: @tenant_a, user: @user) }
    ActsAsTenant.with_tenant(@tenant_b) { FactoryBot.create(:tenant_user, tenant: @tenant_b, user: @user) }

    visit new_user_session_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
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
      wait_for_stimulus "dropdown"
      find("[data-action='dropdown#toggle']").click
      assert_selector "[role='menu']", visible: true

      # Click whichever tenant is a button (not the current one which is a div)
      within("[role='menu']") do
        find("button[type='submit']", match: :first).click
      end
      screenshot("after_switch")

      new_style = evaluate_script("document.getElementById('tenant-theme')?.textContent || ''")
      assert_not_equal initial_style, new_style, "CSS variables should change after tenant switch"
    end
  end
end

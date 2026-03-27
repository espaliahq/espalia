# frozen_string_literal: true

require "application_system_test_case"

class UserMenuSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant, name: "Acme Corp")
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }

    visit new_user_session_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end

  context "user menu dropdown" do
    should "show user initial in trigger" do
      visit root_path
      screenshot("user_initial_visible")

      initial = @user.email.chr.upcase
      assert_selector "[data-action='dropdown#toggle']", text: initial
    end

    should "open dropdown with email and sign out" do
      visit root_path
      wait_for_stimulus "dropdown"

      find("[data-action='dropdown#toggle']").click
      screenshot("dropdown_open")

      assert_selector "[role='menu']", visible: true
      assert_text @user.email
      assert_text "Sign out"
    end

    should "close dropdown when clicking outside" do
      visit root_path
      wait_for_stimulus "dropdown"

      find("[data-action='dropdown#toggle']").click
      assert_selector "[role='menu']", visible: true

      find("main").click
      screenshot("dropdown_closed_after_outside_click")

      assert_no_selector "[role='menu']", visible: true
    end

    should "sign out via dropdown" do
      visit root_path
      wait_for_stimulus "dropdown"

      find("[data-action='dropdown#toggle']").click
      assert_selector "[role='menu']", visible: true
      click_on "Sign out"
      screenshot("after_sign_out")

      assert_current_path new_user_session_path
    end
  end

  context "tenant switcher" do
    should "not show tenant switcher for single-tenant user" do
      visit root_path
      wait_for_stimulus "dropdown"

      find("[data-action='dropdown#toggle']").click
      screenshot("single_tenant_no_switcher")

      assert_no_text "switch workspace"
    end

    should "show tenant switcher for multi-tenant user" do
      second_tenant = FactoryBot.create(:tenant, name: "Beta Inc")
      ActsAsTenant.with_tenant(second_tenant) do
        FactoryBot.create(:tenant_user, tenant: second_tenant, user: @user)
      end

      visit root_path
      wait_for_stimulus "dropdown"
      find("[data-action='dropdown#toggle']").click
      screenshot("multi_tenant_switcher")

      assert_text "SWITCH WORKSPACE"
      assert_text "Acme Corp"
      assert_text "Beta Inc"
    end

    should "switch tenant when clicking another tenant" do
      second_tenant = FactoryBot.create(:tenant, name: "Beta Inc")
      ActsAsTenant.with_tenant(second_tenant) do
        FactoryBot.create(:tenant_user, tenant: second_tenant, user: @user)
      end

      visit root_path
      wait_for_stimulus "dropdown"
      find("[data-action='dropdown#toggle']").click
      assert_selector "[role='menu']", visible: true
      screenshot("before_tenant_switch")

      # Click the switch button for Beta Inc
      within("[role='menu']") do
        click_button "Beta Inc"
      end
      screenshot("after_tenant_switch")

      assert_current_path root_path
    end
  end
end

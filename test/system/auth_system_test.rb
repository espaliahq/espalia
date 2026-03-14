# frozen_string_literal: true

require "application_system_test_case"

class AuthSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { FactoryBot.create(:tenant_user, tenant: @tenant, user: @user) }
    visit new_user_session_path
  end

  context "sign in page" do
    should "render branded sign-in page with all form elements" do
      visit new_user_session_path
      screenshot("sign_in_page")

      assert_text "GrowthOS"
      assert_text "Career growth for your team"
      assert_text "Sign in to your account"
      assert_selector "input[type='email']"
      assert_selector "input[type='password']"
      assert_selector "input[type='checkbox']"
      assert_selector "button[type='submit']", text: "Log in"
      assert_text "Create an account"
      assert_text "Forgot your password?"
    end
  end

  context "successful sign in" do
    should "redirect to dashboard after valid login" do
      visit new_user_session_path

      fill_in "Email", with: @user.email
      fill_in "Password", with: "password123"
      screenshot("credentials_filled")

      click_button "Log in"
      screenshot("post_login_dashboard")

      assert_current_path root_path
      assert_text "GrowthOS"
      assert_text "Welcome to GrowthOS"
    end
  end

  context "failed sign in" do
    should "show an error alert for invalid credentials" do
      visit new_user_session_path

      fill_in "Email", with: "wrong@example.com"
      fill_in "Password", with: "wrongpassword"
      click_button "Log in"
      screenshot("invalid_credentials_error")

      assert_current_path new_user_session_path
      assert_selector "[role='alert']"
      assert_text "Invalid email or password."
    end
  end
end

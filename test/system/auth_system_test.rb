# frozen_string_literal: true

require "application_system_test_case"

class AuthSystemTest < ApplicationSystemTestCase
  include ContrastHelpers

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

  context "sign in page layout" do
    should "fit the desktop viewport with the brand mark" do
      visit new_user_session_path

      assert_selector "svg[data-brand-mark]"
      assert_no_sideways_scroll
      assert_control_heights([ "#user_email", "#user_password", "button[type='submit']" ]) { |height| height == 40 }
    end

    should "fit the mobile viewport with 44px controls" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit new_user_session_path
      screenshot("sign_in_page_mobile")

      assert_selector "svg[data-brand-mark]"
      assert_no_sideways_scroll
      assert_control_heights([ "#user_email", "#user_password", "button[type='submit']",
                               "label[for='user_remember_me']", "a" ]) { |height| height >= 44 }
    end
  end

  context "sign in page contrast" do
    should "clear AA for its text in light mode" do
      visit new_user_session_path
      assert_text "Sign in to your account"

      assert_contrast_clears_aa
    end

    should "clear AA for its text in dark mode" do
      emulate_color_scheme("dark")
      visit new_user_session_path
      assert_text "Sign in to your account"
      log_in_fill = page.evaluate_script("getComputedStyle(document.querySelector(#{log_in_css.to_json})).backgroundColor")
      assert_equal "rgb(251, 251, 255)", log_in_fill, "the dark theme didn't apply"

      assert_contrast_clears_aa
    ensure
      emulate_color_scheme("light")
    end
  end

  context "successful sign in" do
    should "redirect to dashboard after valid login" do
      visit new_user_session_path

      js_fill_in "Email", with: @user.email
      js_fill_in "Password", with: "password123"
      screenshot("credentials_filled")

      click_button_with_js_fallback("Log in", expect_selector: "#user-menu")
      screenshot("post_login_dashboard")

      # Sign-in lands on the Home dashboard.
      assert_current_path root_path
      assert_text "GrowthOS"
    end
  end

  context "failed sign in" do
    should "show an error alert for invalid credentials" do
      visit new_user_session_path

      js_fill_in "Email", with: "wrong@example.com"
      js_fill_in "Password", with: "wrongpassword"
      click_button_with_js_fallback("Log in", expect_selector: "[role='alert']")

      # Wait for the Turbo response to render the flash alert before asserting.
      # The URL doesn't change (POST and GET share the same path), so
      # assert_current_path would pass immediately without waiting.
      assert_selector "[role='alert']", text: "Invalid email or password."
      assert_operator rendered_contrast("[role='alert']"), :>=, 4.5
      screenshot("invalid_credentials_error")
      assert_current_path new_user_session_path
    end
  end

  context "Google sign in" do
    setup do
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: "google_oauth2",
        uid: "google-uid-system",
        info: { "email" => @user.email, "email_verified" => true, "name" => @user.email },
        extra: { raw_info: { "email_verified" => true } }
      )
    end

    teardown { OmniAuth.config.mock_auth[:google_oauth2] = nil }

    should "sign in via the Continue with Google button" do
      visit new_user_session_path
      assert_selector "button[type='submit']", text: "Continue with Google"

      # On starved CI runners the Capybara pointer click on the OAuth
      # button can be dropped, leaving the test on /users/sign_in. The
      # JS-fallback helper escalates to a synthetic JS click and then
      # form.requestSubmit() if the destination text doesn't appear.
      # "Your next actions across GrowthOS." is unique to the post-login
      # Home dashboard (the sign-in page only says "GrowthOS").
      click_button_with_js_fallback "Continue with Google",
        expect_text: "Your next actions across GrowthOS."

      assert_current_path root_path
    end
  end

  private

  def assert_no_sideways_scroll
    widths = page.evaluate_script("[document.documentElement.scrollWidth, document.documentElement.clientWidth]")
    assert_operator widths[0], :<=, widths[1], "the page scrolls sideways (scrollWidth #{widths[0]} > #{widths[1]})"
  end

  def log_in_css = "#{SIGN_IN_FORM_SELECTOR} button[type='submit']"

  def assert_contrast_clears_aa
    assert_selector log_in_css, text: "Log in"

    [ log_in_css, "#sign-in-divider", ".auth-page p", "a[href='#{new_user_registration_path}']",
      "a[href='#{new_user_password_path}']" ].each do |css|
      assert_operator rendered_contrast(css), :>=, 4.5, "#{css} fails AA"
    end
  end

  def assert_control_heights(selectors)
    selectors.each do |css|
      all(css).each do |control|
        height = page.evaluate_script("arguments[0].getBoundingClientRect().height", control)
        assert yield(height), "#{css} (#{control.text.presence || control[:id]}) is #{height}px tall"
      end
    end
  end

  def emulate_color_scheme(scheme)
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: scheme } ]
    )
  end
end

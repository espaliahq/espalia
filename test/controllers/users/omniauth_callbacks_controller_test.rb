# frozen_string_literal: true

require "test_helper"

class Users::OmniauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.application.env_config["devise.mapping"] = Devise.mappings[:user]
  end

  context "GET /users/auth/google_oauth2/callback" do
    should "sign in an existing user matched by email and redirect to root" do
      user = create(:user, email: "alice@example.com")
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: "google_oauth2",
        uid: "uid-100",
        info: { "email" => "Alice@example.com", "email_verified" => true, "name" => "Alice" },
        extra: { raw_info: { "email_verified" => true } }
      )
      Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]

      get user_google_oauth2_omniauth_callback_path

      assert_redirected_to root_path
      user.reload
      assert_equal "google_oauth2", user.provider
      assert_equal "uid-100", user.uid
    end

    should "redirect to sign-in with an alert when the email is unverified" do
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: "google_oauth2",
        uid: "uid-200",
        info: { "email" => "fake@example.com", "email_verified" => false },
        extra: { raw_info: { "email_verified" => false } }
      )
      Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]

      get user_google_oauth2_omniauth_callback_path

      assert_redirected_to new_user_session_path
      assert_match(/isn't verified/, flash[:alert])
    end

    should "redirect to sign-in when no User and no Person matches" do
      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: "google_oauth2",
        uid: "uid-300",
        info: { "email" => "stranger@example.com", "email_verified" => true },
        extra: { raw_info: { "email_verified" => true } }
      )
      Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:google_oauth2]

      get user_google_oauth2_omniauth_callback_path

      assert_redirected_to new_user_session_path
      assert_match(/No GrowthOS account/, flash[:alert])
    end
  end

  context "GET /users/auth/failure" do
    should "redirect to sign-in with the failure message" do
      OmniAuth.config.mock_auth[:google_oauth2] = :invalid_credentials

      get user_google_oauth2_omniauth_callback_path, params: { state: "x" }
      follow_redirect!

      assert_response :success
    end
  end
end

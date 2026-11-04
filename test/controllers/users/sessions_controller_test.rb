# frozen_string_literal: true

require "test_helper"

class Users::SessionsControllerTest < ActionDispatch::IntegrationTest
  def with_google_sso(available)
    was = Rails.configuration.x.google_sso_available
    Rails.configuration.x.google_sso_available = available
    yield
  ensure
    Rails.configuration.x.google_sso_available = was
  end

  context "the sign-in page" do
    should "offer Google while the instance has it (or outside production)" do
      with_google_sso(true) do
        get new_user_session_path
      end

      assert_response :success
      assert_includes response.body, "Continue with Google"
    end

    should "offer only email and password when the instance has no Google SSO" do
      with_google_sso(false) do
        get new_user_session_path
      end

      assert_response :success
      assert_not_includes response.body, "Continue with Google"
      assert_select "input[name='user[email]']"
    end
  end
end

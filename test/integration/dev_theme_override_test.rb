# frozen_string_literal: true

require "test_helper"

class DevThemeOverrideTest < ActionDispatch::IntegrationTest
  context "in development" do
    setup do
      # Loads the lazy routes before the stub: under "development" they mount Lookbook, which test doesn't load
      new_user_session_path
      @env = ActiveSupport::EnvironmentInquirer.new("development")
    end

    should "apply ?scheme to <html> and remember it" do
      Rails.stub(:env, @env) do
        get new_user_session_path(scheme: "dark")
        assert_select "html[data-scheme='dark']"

        get new_user_session_path
        assert_select "html[data-scheme='dark']"
      end
    end

    should "clear the scheme on ?scheme=auto" do
      Rails.stub(:env, @env) do
        get new_user_session_path(scheme: "light")
        get new_user_session_path(scheme: "auto")
        assert_select "html[data-scheme]", count: 0
      end
    end

    should "apply ?theme=bento to <html> and remember it until ?theme=default" do
      Rails.stub(:env, @env) do
        get new_user_password_path(theme: "bento")
        assert_select "html[data-theme='bento']"

        get new_user_password_path
        assert_select "html[data-theme='bento']"

        get new_user_password_path(theme: "default")
        assert_select "html[data-theme]", count: 0
      end
    end

    should "ignore a theme with no preset" do
      Rails.stub(:env, @env) do
        get new_user_password_path(theme: "no-such-preset")
        assert_select "html[data-theme]", count: 0
      end
    end
  end

  should "ignore the override outside development" do
    get new_user_session_path(scheme: "dark")
    assert_select "html[data-scheme]", count: 0
  end
end

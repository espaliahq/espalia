# frozen_string_literal: true

require "test_helper"

class DevThemeOverrideTest < ActionDispatch::IntegrationTest
  context "in development" do
    setup { @env = ActiveSupport::EnvironmentInquirer.new("development") }

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

    should "ignore a theme with no preset" do
      Rails.stub(:env, @env) do
        get new_user_session_path(theme: "no-such-preset")
        assert_select "html[data-theme]", count: 0
      end
    end
  end

  should "ignore the override outside development" do
    get new_user_session_path(scheme: "dark")
    assert_select "html[data-scheme]", count: 0
  end
end

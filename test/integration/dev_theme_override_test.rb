# frozen_string_literal: true

require "test_helper"

class DevThemeOverrideTest < ActionDispatch::IntegrationTest
  context "in development" do
    setup { @env = ActiveSupport::EnvironmentInquirer.new("development") }

    should "apply ?theme and ?scheme to <html> and remember them" do
      Rails.stub(:env, @env) do
        get new_user_session_path(theme: "bento", scheme: "dark")
        assert_select "html[data-theme='bento'][data-scheme='dark']"

        get new_user_session_path
        assert_select "html[data-theme='bento'][data-scheme='dark']"
      end
    end

    should "clear the override on ?theme=default and ?scheme=auto" do
      Rails.stub(:env, @env) do
        get new_user_session_path(theme: "bento", scheme: "light")
        get new_user_session_path(theme: "default", scheme: "auto")
        assert_select "html[data-theme]", count: 0
        assert_select "html[data-scheme]", count: 0
      end
    end
  end

  should "ignore the override outside development" do
    get new_user_session_path(theme: "bento", scheme: "dark")
    assert_select "html[data-theme]", count: 0
    assert_select "html[data-scheme]", count: 0
  end
end

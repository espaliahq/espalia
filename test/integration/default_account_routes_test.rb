# frozen_string_literal: true

require "test_helper"

class DefaultAccountRoutesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  {
    "self sign-up" => [ [ :get, "/users/sign_up" ], [ :post, "/users" ] ],
    "edit account" => [ [ :get, "/users/edit" ], [ :patch, "/users" ], [ :put, "/users" ] ],
    "delete account" => [ [ :get, "/users/cancel" ], [ :delete, "/users" ] ]
  }.each do |flow, requests|
    should "not route #{flow}" do
      requests.each do |verb, path|
        assert_raises(ActionController::RoutingError, "#{verb.upcase} #{path}") do
          Rails.application.routes.recognize_path(path, method: verb)
        end
      end
    end
  end

  should "not mount the registration helpers" do
    helpers = Rails.application.routes.url_helpers

    %i[new_user_registration_path user_registration_path edit_user_registration_path cancel_user_registration_path].each do |helper|
      assert_not helpers.method_defined?(helper), helper
    end
  end

  should "leave an account in place when a signed-in user sends the delete request" do
    user = create(:user)
    sign_in user

    delete "/users"

    assert User.exists?(user.id)
  end

  should "render the sign-in page with no sign-up link" do
    get new_user_session_path

    assert_response :success
    assert_select "a", text: "Create an account", count: 0
    assert_select "a[href=?]", new_user_password_path
  end

  should "render the password pages with no sign-up link" do
    user = create(:user)
    token = user.send_reset_password_instructions

    [ new_user_password_path, edit_user_password_path(reset_password_token: token) ].each do |path|
      get path

      assert_response :success, path
      assert_select "a", text: "Sign up", count: 0
      assert_select "a[href=?]", new_user_session_path
    end
  end
end

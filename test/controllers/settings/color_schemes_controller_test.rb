# frozen_string_literal: true

require "test_helper"

class Settings::ColorSchemesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  TURBO_STREAM = { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }.freeze

  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :member) }
  end

  context "PATCH /settings/color_scheme" do
    should "redirect unauthenticated users" do
      patch settings_color_scheme_path, params: { color_scheme: "dark" }
      assert_redirected_to new_user_session_path
    end

    context "signed in" do
      setup { sign_in @user }

      should "save the choice and answer Turbo with no content" do
        patch settings_color_scheme_path, params: { color_scheme: "dark" }, headers: TURBO_STREAM
        assert_response :no_content
        assert_equal "dark", @user.reload.color_scheme
      end

      should "answer JSON with no content" do
        patch settings_color_scheme_path, params: { color_scheme: "light" }, as: :json
        assert_response :no_content
        assert_equal "light", @user.reload.color_scheme
      end

      should "send a plain form post back where it came from" do
        patch settings_color_scheme_path, params: { color_scheme: "light" }, headers: { "HTTP_REFERER" => settings_notifications_url }
        assert_redirected_to settings_notifications_url
        assert_equal "light", @user.reload.color_scheme
      end

      should "go back to auto" do
        @user.update!(color_scheme: :dark)
        patch settings_color_scheme_path, params: { color_scheme: "auto" }, headers: TURBO_STREAM
        assert_response :no_content
        assert @user.reload.color_scheme_auto?
      end

      should "refuse a value outside auto, light and dark" do
        patch settings_color_scheme_path, params: { color_scheme: "sepia" }, headers: TURBO_STREAM
        assert_response :unprocessable_content
        assert @user.reload.color_scheme_auto?
      end

      should "answer a nested color_scheme param with Bad Request" do
        patch settings_color_scheme_path, params: { color_scheme: { value: "dark" } }, headers: TURBO_STREAM
        assert_response :bad_request
        assert @user.reload.color_scheme_auto?
      end

      should "change only the signed-in user, whatever the params name" do
        other = create(:user)
        patch settings_color_scheme_path, params: { color_scheme: "dark", user_id: other.id, id: other.id }, headers: TURBO_STREAM
        assert_response :no_content
        assert other.reload.color_scheme_auto?
        assert_equal "dark", @user.reload.color_scheme
      end
    end
  end
end

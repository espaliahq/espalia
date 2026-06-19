# frozen_string_literal: true

require "test_helper"

class Settings::NotificationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :member) }
  end

  context "GET /settings/notifications" do
    should "redirect unauthenticated users" do
      get settings_notifications_path
      assert_redirected_to new_user_session_path
    end

    should "render the preference matrix for each notification type" do
      sign_in @user
      get settings_notifications_path
      assert_response :success
      assert_match "Evidence requested from you", response.body
      assert_match "notification_preferences[evidence_requested][slack]", response.body
    end
  end

  context "PATCH /settings/notifications" do
    setup { sign_in @user }

    should "persist submitted overrides" do
      patch settings_notifications_path, params: {
        notification_preferences: {
          evidence_requested: { in_app: "1", slack: "0" }
        }
      }
      assert_redirected_to settings_notifications_path

      @user.reload
      assert @user.notifies_via?(:evidence_requested, :in_app)
      assert_not @user.notifies_via?(:evidence_requested, :slack)
    end

    should "treat an omitted checkbox as disabled via its hidden companion" do
      # Simulate the hidden-field default for an unchecked box.
      patch settings_notifications_path, params: {
        notification_preferences: {
          evidence_request_responded: { in_app: "0", slack: "0" }
        }
      }
      @user.reload
      assert_not @user.notifies_via?(:evidence_request_responded, :in_app)
    end
  end
end

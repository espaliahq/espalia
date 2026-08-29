# frozen_string_literal: true

require "application_system_test_case"

class Settings::NotificationsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :member) }
    sign_in_as(@user)
  end

  should "let a user turn off a channel for a notification type" do
    visit settings_notifications_path
    assert_text "Feedback requested from you"

    # Slack defaults on for evidence_requested.
    assert page.has_checked_field?("notif-evidence_requested-slack", visible: :all)
    uncheck "notif-evidence_requested-slack", allow_label_click: true, visible: :all

    click_button_with_js_fallback("Save preferences", expect_text: "Notification preferences saved")

    assert_not @user.reload.notifies_via?(:evidence_requested, :slack)
    assert @user.notifies_via?(:evidence_requested, :in_app)
  end
end

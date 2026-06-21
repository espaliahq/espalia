# frozen_string_literal: true

require "test_helper"
require_relative "../support/inbox_test_notifier"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :member) }
  end

  def notify!(user, title: "Hi", **params)
    InboxTestNotifier.with(title: title, **params).deliver(user)
    user.notifications.reload
  end

  context "GET /notifications" do
    should "redirect unauthenticated users" do
      get notifications_path
      assert_redirected_to new_user_session_path
    end

    should "list the user's surfaced notifications" do
      sign_in @user
      notify!(@user, title: "Alpha")

      get notifications_path
      assert_response :success
      assert_match "Test: Alpha", response.body
    end

    should "hide notifications whose type the user disabled in-app" do
      @user.update_notification_preference(:evidence_requested, in_app: false)
      sign_in @user
      notify!(@user, title: "Hidden")

      get notifications_path
      assert_response :success
      assert_no_match "Test: Hidden", response.body
    end

    should "render notification text in full (no truncation) in the inbox" do
      sign_in @user
      notify!(@user, title: "Alpha", body: "A long decline reason that must not be clamped")

      get notifications_path
      assert_response :success
      assert_match "A long decline reason that must not be clamped", response.body
      assert_match "break-words", response.body
      # Body is never clamped; the title isn't truncated either (the bell frame,
      # which has no layout chrome, asserts truncate-absence directly below).
      assert_no_match "line-clamp-2", response.body
    end
  end

  context "GET /notifications/bell" do
    should "render the bell frame with an unread count" do
      sign_in @user
      notify!(@user, title: "One")
      notify!(@user, title: "Two")

      get bell_notifications_path
      assert_response :success
      assert_match "2 unread", response.body
    end

    should "render bell notification text in full (no truncation)" do
      sign_in @user
      notify!(@user, title: "One", body: "A long body that must show in full in the bell too")

      get bell_notifications_path
      assert_response :success
      assert_match "A long body that must show in full in the bell too", response.body
      assert_no_match "line-clamp-2", response.body
      assert_no_match "truncate", response.body
    end
  end

  context "PATCH /notifications/:id" do
    should "mark read and redirect to the sanitized target url" do
      sign_in @user
      notify!(@user, title: "Click", url: "/assessments")
      notification = @user.notifications.first

      patch notification_path(notification)
      assert_redirected_to "/assessments"
      assert notification.reload.read?
    end

    should "fall back to the inbox for an off-site target url" do
      sign_in @user
      notify!(@user, title: "Evil", url: "//evil.example.com")
      notification = @user.notifications.first

      patch notification_path(notification)
      assert_redirected_to notifications_path
    end

    should "preserve a deep-link #anchor in the redirect target" do
      sign_in @user
      notify!(@user, title: "Deep", url: "/evidence#evidence-request-abc123")
      notification = @user.notifications.first

      patch notification_path(notification)
      assert_redirected_to "/evidence#evidence-request-abc123"
    end

    should "not let a user mark another user's notification read" do
      other = create(:user, password: "password123")
      notify!(other, title: "Theirs")
      notification = other.notifications.first
      sign_in @user

      patch notification_path(notification)
      assert_redirected_to root_path
      assert notification.reload.unread?
    end
  end

  context "POST /notifications/read_all" do
    should "mark every unread notification read" do
      sign_in @user
      notify!(@user, title: "A")
      notify!(@user, title: "B")

      post read_all_notifications_path
      assert @user.notifications.reload.all?(&:read?)
    end
  end
end

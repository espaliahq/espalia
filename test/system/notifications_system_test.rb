# frozen_string_literal: true

require "application_system_test_case"
require_relative "../support/inbox_test_notifier"

class NotificationsSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    @tenant = create(:tenant)
    @user = create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) { create(:tenant_user, tenant: @tenant, user: @user, role: :member) }
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    sign_in_as(@user)
  end

  def notify!(title:, **params)
    InboxTestNotifier.with(title: title, **params).deliver(@user)
  end

  should "show the bell with no badge when there are no notifications" do
    visit root_path
    assert_selector "turbo-frame#notification-bell a[aria-label='Notifications']"
    assert_no_selector "turbo-frame#notification-bell span", text: /\d/
  end

  should "surface a delivered notification in the inbox and clear it on read" do
    notify!(title: "Peer feedback", body: "Please add evidence", url: "/")

    visit notifications_path
    assert_text "Test: Peer feedback"
    assert_text "Please add evidence"

    # Bell shows the unread count after a fresh load.
    visit root_path
    assert_selector "turbo-frame#notification-bell span", text: "1"

    # Reading the notification (click navigates to its target) clears the badge.
    visit notifications_path
    find("a", text: "Test: Peer feedback").click
    assert_selector "turbo-frame#notification-bell a[aria-label='Notifications']"
    assert_no_selector "turbo-frame#notification-bell span", text: /\d/
  end

  should "mark all notifications read from the inbox" do
    notify!(title: "One")
    notify!(title: "Two")

    visit notifications_path
    assert_text "Test: One"
    find("a", text: "Mark all as read").click
    # Once all are read the bulk link disappears.
    assert_no_selector "a", text: "Mark all as read"

    visit root_path
    assert_no_selector "turbo-frame#notification-bell span", text: /\d/
  end

  should "show the bell on a mobile viewport" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    notify!(title: "Mobile")
    visit root_path
    assert_selector "turbo-frame#notification-bell span", text: "1"
  end
end

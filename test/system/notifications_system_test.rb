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
    assert_selector "turbo-frame#notification-bell button[aria-label='Notifications']"
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
    click_button_with_js_fallback(
      "Test: Peer feedback",
      expect_selector: "turbo-frame#notification-bell button[aria-label='Notifications']"
    )
    assert_selector "turbo-frame#notification-bell button[aria-label='Notifications']"
    assert_no_selector "turbo-frame#notification-bell span", text: /\d/
  end

  should "mark all notifications read from the inbox" do
    notify!(title: "One")
    notify!(title: "Two")

    visit notifications_path
    assert_text "Test: One"
    # JS-dispatch the Turbo POST link so a starved CI event loop can't drop the
    # click (Turbo's data-turbo-method listener still intercepts el.click()).
    page.execute_script(
      "[...document.querySelectorAll('a')].find((a) => a.textContent.trim() === 'Mark all as read').click()"
    )
    # Once all are read the bulk link disappears.
    assert_no_selector "a", text: "Mark all as read"

    visit root_path
    assert_no_selector "turbo-frame#notification-bell span", text: /\d/
  end

  should "open a dropdown panel of recent notifications when the bell is clicked" do
    notify!(title: "Clickthrough")
    visit root_path

    open_dropdown(scope: "turbo-frame#notification-bell")
    within "turbo-frame#notification-bell" do
      assert_text "Test: Clickthrough"
      assert_link "View all notifications"
    end
  end

  should "link notification preferences from the bell panel's gear" do
    notify!(title: "Prefs entry point")
    visit root_path

    open_dropdown(scope: "turbo-frame#notification-bell")
    # Icon-only control — locate by aria-label; sync on text unique to the
    # preferences page (the panel header also says "Notifications").
    click_selector_with_js_fallback(
      "turbo-frame#notification-bell a[aria-label='Notification preferences']",
      expect_text: "Feedback requested from you"
    )

    assert_current_path settings_notifications_path
  end

  should "navigate to the full inbox via 'View all' (frame breaks out to _top)" do
    notify!(title: "Full list")
    visit root_path

    open_dropdown(scope: "turbo-frame#notification-bell")
    # h1 is unique to the notifications index — "Notifications" alone also
    # appears in the bell panel, and an expectation the current page already
    # satisfies can never arm the fallback.
    click_selector_with_js_fallback(
      "turbo-frame#notification-bell a[href='#{notifications_path}']",
      expect_selector: "h1"
    )

    assert_current_path notifications_path
    assert_text "Test: Full list"
  end

  should "show the bell on a mobile viewport" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    notify!(title: "Mobile")
    visit root_path
    assert_selector "turbo-frame#notification-bell span", text: "1"
  end

  should "link notification preferences from the mobile bell panel" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    notify!(title: "Mobile preferences")
    visit root_path

    open_dropdown(scope: "turbo-frame#notification-bell")
    click_selector_with_js_fallback(
      "turbo-frame#notification-bell a[aria-label='Notification preferences']",
      expect_text: "Feedback requested from you"
    )

    assert_current_path settings_notifications_path
  end

  should "keep the dropdown panel fully on-screen on a mobile viewport" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    notify!(title: "Mobile panel")
    visit root_path

    open_dropdown(scope: "turbo-frame#notification-bell")
    rect = page.evaluate_script(
      "document.querySelector(\"turbo-frame#notification-bell [data-dropdown-target='menu']\")" \
      ".getBoundingClientRect().toJSON()"
    )
    assert_operator rect["left"], :>=, 0, "panel clipped off the left viewport edge"
    assert_operator rect["right"], :<=, 375, "panel clipped off the right viewport edge"
  end
end

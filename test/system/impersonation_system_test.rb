# frozen_string_literal: true

require "application_system_test_case"

# Exercises the tenant-admin "view as another user" UX: the "View as"
# affordance on the admin user list, the sticky read-only banner, and the
# "Stop impersonating" exit.
class ImpersonationSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user  = FactoryBot.create(:user, password: "password123")
    @member_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      member_person = FactoryBot.create(:person, tenant: @tenant, name: "Casey Member", email: @member_user.email)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @member_user, person: member_person, role: :member)
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  end

  should "offer 'View as' for a member and not for the admin themselves" do
    sign_in_as(@admin_user)
    visit tenant_users_path
    assert_text "Tenant users"

    # Exactly one impersonable target (the member) — the admin's own row
    # and any other admins are not offered.
    assert_selector "button", text: "View as", count: 1
  end

  should "start impersonating, show the banner, and stop" do
    sign_in_as(@admin_user)
    visit tenant_users_path
    assert_text "Tenant users"

    click_button_with_js_fallback "View as", expect_text: "Viewing as"
    assert_text "Casey Member"
    assert_text "read-only"

    # Stopping returns to root, which renders the Home dashboard.
    click_button_with_js_fallback "Stop impersonating", expect_text: "Your next actions across GrowthOS."
    assert_no_text "Viewing as"
  end

  should "hide admin-only nav links while impersonating a non-admin member" do
    sign_in_as(@admin_user)
    visit root_path
    assert_text "Your next actions across GrowthOS."

    # Nav-scoped CSS selectors (not `within "nav"`) so each retry re-queries
    # the navbar — a `within` block caches the <nav> node, which Turbo Drive
    # detaches when it replaces the body on the redirect-to-root below.

    # Baseline: the admin sees the admin-only links in the navbar.
    assert_selector "nav a", text: "Admin"
    assert_selector "nav a", text: "Cycles"

    visit tenant_users_path
    assert_text "Tenant users"
    click_button_with_js_fallback "View as", expect_text: "Viewing as"

    # While impersonating the member, the navbar renders the member's
    # perspective — the admin-only links are gone.
    assert_no_selector "nav a", text: "Admin"
    assert_no_selector "nav a", text: "Cycles"

    # Stopping restores the admin's own navbar.
    click_button_with_js_fallback "Stop impersonating", expect_text: "Your next actions across GrowthOS."
    assert_selector "nav a", text: "Admin"
    assert_selector "nav a", text: "Cycles"
  end
end

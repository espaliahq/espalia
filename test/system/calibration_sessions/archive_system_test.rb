# frozen_string_literal: true

require "application_system_test_case"

# The calibration list: grouped by cycle, archived sessions hidden behind a
# "Show archived (N)" toggle, and a kebab per card with Open · Rename… ·
# Archive / Restore (#521). Checked at both viewports — the list is the one
# calibration surface a phone reaches.
class CalibrationSessions::ArchiveSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    @facilitator_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @facilitator = create(:person, tenant: @tenant, email: @facilitator_user.email, name: "Dana Dept")
      em = create(:person, tenant: @tenant, name: "Mia Manager", manager: @facilitator)
      report = create(:person, tenant: @tenant, name: "Ivy IC", manager: em)
      create(:tenant_user, tenant: @tenant, user: @facilitator_user, person: @facilitator)

      cycle = create(:assessment_cycle, tenant: @tenant, name: "H1 2026 Review")
      context = AuthorizationContext.new(
        user: @facilitator_user, tenant_user: TenantUser.find_by(user: @facilitator_user), person: @facilitator
      )
      define = lambda do |name|
        Operations::CalibrationSessions::Define.call(
          context: context,
          params: { cycle_id: cycle.cycle_id, name: name,
                    participant_ids: [ em.id ], calibrant_person_ids: [ report.id ] }
        )[:session_id]
      end
      @live_id = define.call("Engineering · live")
      @closed_id = define.call("Engineering · closed")
      Operations::CalibrationSessions::Start.call(context: context, params: { session_id: @live_id })
      Operations::CalibrationSessions::Close.call(context: context, params: { session_id: @closed_id })
    end
  end

  [ [ "desktop", ApplicationSystemTestCase::DESKTOP_SIZE ],
    [ "mobile", ApplicationSystemTestCase::MOBILE_SIZE ] ].each do |label, size|
    should "archive a closed session from its kebab and restore it on #{label}" do
      page.driver.browser.manage.window.resize_to(*size)
      sign_in_as(@facilitator_user)
      visit calibration_sessions_path
      assert_selector "h2", text: "H1 2026 Review"
      assert_no_text "Show archived"
      assert_no_sideways_scroll

      open_dropdown(scope: card(@closed_id))
      within(card(@closed_id)) do
        assert_selector "[role='menuitem']", text: "Open"
        assert_selector "[role='menuitem']", text: "Rename…"
      end
      click_selector_with_js_fallback "#{card(@closed_id)} form[action$='/archive'] button",
                                      expect_text: "archived. Show archived"
      assert_no_selector card(@closed_id)
      assert_selector card(@live_id)

      click_link_with_js_fallback "Show archived (1)", expect_text: "Hide archived"
      within("section[aria-labelledby='archived-sessions']") do
        assert_selector card(@closed_id), text: "Archived"
        assert_text "by Dana Dept"
      end
      assert_no_sideways_scroll

      click_selector_with_js_fallback "#{card(@closed_id)} > form[action$='/unarchive'] button",
                                      expect_text: "restored"
      assert_no_selector "section[aria-labelledby='archived-sessions']"
    end
  end

  should "offer no Archive on a live session" do
    sign_in_as(@facilitator_user)
    visit calibration_sessions_path
    assert_selector card(@live_id)

    open_dropdown(scope: card(@live_id))
    within(card(@live_id)) do
      assert_selector "[role='menuitem']", text: "Rename…"
      assert_no_selector "[role='menuitem']", text: "Archive"
    end
  end

  should "rename a closed session from the kebab's dialog" do
    sign_in_as(@facilitator_user)
    visit calibration_sessions_path
    assert_selector card(@closed_id)

    open_dropdown(scope: card(@closed_id))
    within(card(@closed_id)) do
      page.execute_script("arguments[0].click()", find("[role='menuitem']", text: "Rename…"))
    end
    assert_selector "##{Views::CalibrationSessions::RenameSessionModal::ID}", visible: true
    assert_equal "Engineering · closed", find_field("Name").value

    js_fill_in "Name", with: "Engineering · H1 2026"
    click_button_with_js_fallback "Save", expect_text: "Renamed to “Engineering · H1 2026”"
    assert_selector card(@closed_id), text: "Engineering · H1 2026"
  end

  private

  def assert_no_sideways_scroll
    assert_equal page.evaluate_script("document.documentElement.clientWidth"),
                 page.evaluate_script("document.documentElement.scrollWidth"), "no sideways overflow"
  end

  def card(session_id)
    "#calibration-session-card-#{session_id}"
  end
end

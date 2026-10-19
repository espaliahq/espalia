# frozen_string_literal: true

require "application_system_test_case"

# Rename a calibration session in place from the pencil beside its name —
# the framework-rename pattern (#521). DESKTOP_SIZE / MOBILE_SIZE and the
# desktop reset in setup come from ApplicationSystemTestCase.
class CalibrationSessions::RenameSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    @facilitator_user = create(:user, password: "password123")
    @admin_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @facilitator = create(:person, tenant: @tenant, email: @facilitator_user.email, name: "Dana Dept")
      em = create(:person, tenant: @tenant, name: "Mia Manager", manager: @facilitator)
      report = create(:person, tenant: @tenant, name: "Ivy IC", manager: em)
      create(:tenant_user, tenant: @tenant, user: @facilitator_user, person: @facilitator)
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin,
             person: create(:person, tenant: @tenant, email: @admin_user.email))

      cycle = create(:assessment_cycle, tenant: @tenant, name: "H1 2026 Review")
      context = AuthorizationContext.new(
        user: @facilitator_user, tenant_user: TenantUser.find_by(user: @facilitator_user), person: @facilitator
      )
      @session_id = Operations::CalibrationSessions::Define.call(
        context: context,
        params: { cycle_id: cycle.cycle_id, name: "Engineering · H1",
                  participant_ids: [ em.id ], calibrant_person_ids: [ report.id ] }
      )[:session_id]
      # Live, so the page carries the session log the rename line lands in.
      Operations::CalibrationSessions::Start.call(context: context, params: { session_id: @session_id })
    end
  end

  should "rename from the pencil on desktop, and the log says what it was called" do
    sign_in_as(@facilitator_user)
    visit calibration_session_path(@session_id)
    assert_selector "h1", text: "Engineering · H1"

    submit_rename("Engineering · H1 2026")
    assert_selector "h1", text: "Engineering · H1 2026"
    assert_no_selector "[data-editor-form]"

    visit calibration_session_path(@session_id)
    assert_selector "h1", text: "Engineering · H1 2026"
    within("#session-log") { assert_text "Renamed to “Engineering · H1 2026” (was “Engineering · H1”)" }
  end

  should "rename from the pencil on mobile" do
    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    sign_in_as(@facilitator_user)
    visit calibration_session_path(@session_id)
    assert_selector "h1", text: "Engineering · H1"

    submit_rename("Mobile renamed")
    assert_selector "h1", text: "Mobile renamed"
    assert_equal page.evaluate_script("document.documentElement.clientWidth"),
                 page.evaluate_script("document.documentElement.scrollWidth"), "no sideways overflow"
  end

  should "refuse a blank name inline and keep the typed text" do
    sign_in_as(@facilitator_user)
    visit calibration_session_path(@session_id)
    assert_selector "h1", text: "Engineering · H1"

    submit_rename("   ")
    assert_text "Couldn’t save: the name can’t be blank"
    within host_selector do
      assert_selector "[data-editor-form]", visible: true
      assert_equal "   ", find("[data-editor-input]").value
    end
    assert_selector "h1", text: "Engineering · H1", visible: :all
  end

  should "offer the pencil to a tenant admin who doesn't facilitate" do
    sign_in_as(@admin_user)
    visit calibration_session_path(@session_id)
    assert_selector "h1", text: "Engineering · H1"
    assert_selector "[aria-label='Rename session']", visible: :all
  end

  private

  def host_selector
    "turbo-frame#calibration-session-name-#{@session_id} > div"
  end

  def submit_rename(value)
    form = start_inline_edit(host_selector)
    assert_equal "calibration_session[name]", form.find("[data-editor-input]", visible: :all)[:name]
    assert_equal "Save", form.find("[data-editor-submit]").text
    submit_inline_edit(form, with: value)
  end
end

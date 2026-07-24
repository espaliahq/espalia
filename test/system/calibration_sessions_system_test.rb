# frozen_string_literal: true

require "application_system_test_case"

class CalibrationSessionsSystemTest < ApplicationSystemTestCase
  setup do
    @tenant = create(:tenant)
    @facilitator_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @facilitator = create(:person, tenant: @tenant, email: @facilitator_user.email, name: "Dana Dept")
      @em_1 = create(:person, tenant: @tenant, name: "Mia Manager", manager: @facilitator)
      @em_2 = create(:person, tenant: @tenant, name: "Raj Rater", manager: @facilitator)
      @report_1 = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em_1)
      @report_2 = create(:person, tenant: @tenant, name: "Omar IC", manager: @em_2)

      create(:tenant_user, tenant: @tenant, user: @facilitator_user, person: @facilitator)
      create(:tenant_user, tenant: @tenant, user: @member_user)

      @cycle = create(:assessment_cycle, tenant: @tenant, name: "H1 2026 Review")
      [ @em_1, @em_2, @report_1, @report_2 ].each do |person|
        create(:person_framework_assignment, tenant: @tenant,
               person_id: person.id, framework_id: @cycle.framework_id)
      end
    end
  end

  test "facilitator defines, curates, and starts a calibration session" do
    sign_in_as(@facilitator_user)

    click_link_with_js_fallback("Calibration", expect_text: "Define calibration session")
    click_link_with_js_fallback("Define calibration session", expect_text: "Participants (raters)")

    fill_in "Session name", with: "Engineering calibration"
    select "H1 2026 Review", from: "Assessment cycle"
    check "Mia Manager"
    check "Raj Rater"
    click_button "Create draft session"

    # Draft page: seeded population grouped by rater, readiness surfaced
    assert_text "Calibration session created"
    assert_text "Engineering calibration"
    assert_text "Mia Manager's reports (1)"
    assert_text "Ivy IC"
    assert_text "Omar IC"
    assert_text "0 of 2 manager-rated"
    assert_text "not enrolled in the cycle"

    # Remove a calibrant — they surface as an explicit re-add suggestion
    find("button[aria-label='Remove Ivy IC from the population']").click
    assert_text "Removed from the population."
    assert_text "Reporting to participants but not in the population:"
    within(".border-dashed") { assert_text "Ivy IC" }

    # Re-add via the suggestion affordance
    find("button[aria-label='Add Ivy IC to the population']").click
    assert_text "Added to the population."
    assert_text "Mia Manager's reports (1)"

    # Start — population freezes, curation affordances disappear
    auto_confirm { click_button "Start session" }
    assert_text "Session started"
    assert_text "Live"
    assert_text "participants and population are frozen"
    assert_no_selector "button[aria-label='Remove Ivy IC from the population']"
    assert_no_text "Add person from your org"
  end

  test "member without reports sees no Calibration nav link" do
    sign_in_as(@member_user)

    assert_text "Home"
    assert_no_selector "a", text: "Calibration"
  end
end

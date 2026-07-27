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

  def rate(person, capability, frequency)
    create(:assessment_level_rating, tenant: @tenant,
           cycle_id: @cycle.cycle_id, person_id: person.id,
           framework_id: @cycle.framework_id,
           capability_stable_id: capability.stable_id, level_ordinal: 3,
           manager_rated_frequency: frequency)
  end

  test "facilitator defines, curates, and starts a calibration session" do
    sign_in_as(@facilitator_user)

    click_link_with_js_fallback("Calibration", expect_text: "Define calibration session")
    click_link_with_js_fallback("Define calibration session", expect_text: "Participants (raters)")

    fill_in "Session name", with: "Engineering calibration"
    select "H1 2026 Review", from: "Assessment cycle"

    # Pick raters via the shared person picker: one from the quick-add
    # suggestions, one through the typeahead search. Stimulus-action
    # buttons are JS-dispatched per the flake guards.
    wait_for_stimulus "person-picker"
    page.execute_script(
      %{document.querySelector("[data-person-picker-target='suggestions'] [data-person-picker-person-id-param='#{@em_1.id}']").click()}
    )
    assert_selector "[data-person-picker-target='selected'] span[data-person-id='#{@em_1.id}']", text: "Mia Manager"

    fill_in "Participants (raters)", with: "Raj"
    assert_selector "turbo-frame#participant-candidates button", text: "Raj Rater"
    page.execute_script(
      %{document.querySelector("turbo-frame#participant-candidates [data-person-picker-person-id-param='#{@em_2.id}']").click()}
    )
    assert_selector "[data-person-picker-target='selected'] span[data-person-id='#{@em_2.id}']", text: "Raj Rater"

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

  test "facilitator sees tendency strip and divergence board on a live session" do
    ActsAsTenant.with_tenant(@tenant) do
      category = create(:framework_capability_category, tenant: @tenant,
                        framework_id: @cycle.framework_id, name: "Thinking")
      @cap_a = create(:framework_capability, tenant: @tenant,
                      category_id: category.category_id, name: "Strategic Thinking")
      cap_b = create(:framework_capability, tenant: @tenant,
                     category_id: category.category_id, name: "Delivery")

      report_3 = create(:person, tenant: @tenant, name: "Nia IC", manager: @em_1)
      report_4 = create(:person, tenant: @tenant, name: "Pax IC", manager: @em_2)
      population = [ @report_1, @report_2, report_3, report_4 ]
      # report_1/2 already hold assignments from setup (DeterministicId PK).
      [ report_3, report_4 ].each do |person|
        create(:person_framework_assignment, tenant: @tenant,
               person_id: person.id, framework_id: @cycle.framework_id)
      end
      population.each do |person|
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: person.id, level_ordinal: 3)
      end
      # Mia rates high, Raj rates low on Strategic Thinking; both agree on Delivery.
      rate(@report_1, @cap_a, "consistent")
      rate(report_3, @cap_a, "consistent")
      rate(@report_2, @cap_a, "none")
      rate(report_4, @cap_a, "none")
      rate(@report_1, cap_b, "occasional")
      rate(@report_2, cap_b, "occasional")

      ctx = AuthorizationContext.new(
        user: @facilitator_user,
        tenant_user: TenantUser.find_by(user: @facilitator_user),
        person: @facilitator
      )
      result = Operations::CalibrationSessions::Define.call(
        context: ctx,
        params: {
          cycle_id: @cycle.cycle_id, name: "Live calibration",
          participant_ids: [ @em_1.id, @em_2.id ],
          calibrant_person_ids: population.map(&:id)
        }
      )
      Operations::CalibrationSessions::Start.call(context: ctx, params: { session_id: result[:session_id] })
      @live_session_id = result[:session_id]
    end

    sign_in_as(@facilitator_user)
    visit calibration_session_path(@live_session_id)

    assert_text "Live calibration"
    # Headings render through CSS `uppercase` — assert the rendered case.
    assert_text "RATER TENDENCY"
    assert_text "Org mean"
    assert_text "Mia Manager"
    assert_text "CAPABILITY DIVERGENCE"
    assert_text "Strategic Thinking"
    assert_text "spread 3.0"
    assert_text "raters disagree"
    # No curation affordances on a live session
    assert_no_text "Add person from your org"

    # ── Drill-in: divergence row → rater × level grid ──
    click_link_with_js_fallback("Strategic Thinking", expect_text: "WHAT GOOD LOOKS LIKE")
    assert_text "AT-LEVEL RATINGS BY RATER"
    assert_selector "a[data-calibration-reveal-target='dot']", minimum: 4

    # Anonymized by default — accessible names are generic
    wait_for_stimulus "calibration-reveal"
    dot = find("a[data-person-id='#{@report_1.id}']")
    assert dot["aria-label"].start_with?("Population member"),
      "dots must not carry names before reveal"

    # Opening a dot IS the reveal: card shows the person, dot becomes named
    click_with_retry(expect_text: "Close") do
      find("a[data-person-id='#{@report_1.id}']").click
    end
    assert_text "Ivy IC"
    assert_text "Manager: Consistently"
    wait_for_stimulus "calibration-reveal"
    assert_selector "a[data-person-id='#{@report_1.id}'][data-revealed='true']"
    assert_selector "a[data-person-id='#{@report_2.id}'][data-revealed='false']"

    # Session-level "Show names" override (JS-dispatched — Stimulus toggle)
    page.execute_script("document.querySelector(\"[data-calibration-reveal-target='toggle']\").click()")
    assert_selector "button[data-calibration-reveal-target='toggle']", text: "Hide names"
    assert_selector "a[data-person-id='#{@report_2.id}'][data-revealed='true']"
  end

  test "facilitator flags an unclear expectation from the drill-in" do
    ActsAsTenant.with_tenant(@tenant) do
      # The flag raises a framework clarification, so this framework needs a
      # real event stream — built through commands, not read-model factories.
      fw_id = SecureRandom.uuid_v7
      cap_stable = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(fw_id, "Eng Framework")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(fw_id, cat_id, "Thinking")
      handler.add_capability(fw_id, cap_id, cap_stable, cat_id, "Strategic Thinking")
      handler.set_behavioural_expectation(fw_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                          cap_id, 3, "Shapes team direction")
      handler.publish_version(fw_id, "test")

      cycle = create(:assessment_cycle, tenant: @tenant, name: "H2 2026 Review", framework_id: fw_id)
      create(:person_framework_assignment, tenant: @tenant, person_id: @report_1.id, framework_id: fw_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle,
             person_id: @report_1.id, level_ordinal: 3)

      ctx = AuthorizationContext.new(
        user: @facilitator_user,
        tenant_user: TenantUser.find_by(user: @facilitator_user),
        person: @facilitator
      )
      result = Operations::CalibrationSessions::Define.call(
        context: ctx,
        params: { cycle_id: cycle.cycle_id, name: "Flag calibration",
                  participant_ids: [ @em_1.id ], calibrant_person_ids: [ @report_1.id ] }
      )
      Operations::CalibrationSessions::Start.call(context: ctx, params: { session_id: result[:session_id] })
      @flag_session_id = result[:session_id]
      @flag_cap_stable = cap_stable
    end

    sign_in_as(@facilitator_user)
    visit calibration_session_capability_path(@flag_session_id, @flag_cap_stable)
    assert_text "WHAT GOOD LOOKS LIKE"
    assert_text "Shapes team direction"

    # Open the per-level disclosure (native <details> — set .open directly;
    # a synthetic summary click can be dropped on starved CI) and raise the
    # clarification.
    assert_selector "summary", text: "⚑ Flag expectation as unclear"
    page.execute_script(<<~JS)
      document.querySelectorAll("details > summary").forEach((s) => {
        if (s.textContent.includes("Flag expectation")) s.parentElement.open = true
      })
    JS
    fill_in "flag-reason-3", with: "Scope or altitude?"
    click_button_with_js_fallback "Raise clarification", expect_text: "clarification discussion is now open"

    # One flag per cell per session: the marker replaces the affordance.
    assert_text "⚑ Flagged — 1 open clarification on the framework"
    assert_no_selector "summary", text: "⚑ Flag expectation as unclear"

    ActsAsTenant.with_tenant(@tenant) do
      clarification = FrameworkState::SuggestedEdit.clarifications.pending.sole
      assert_includes clarification.rationale, "Flagged during Flag calibration"
      assert_includes clarification.rationale, "Scope or altitude?"
      flags = CalibrationSessions::SessionOutcomes.new(session: CalibrationSession.find(@flag_session_id)).flags
      assert_equal clarification.suggestion_id, flags.first[:suggestion_id]
    end
  end

  test "member without reports sees no Calibration nav link" do
    sign_in_as(@member_user)

    assert_text "Home"
    assert_no_selector "a", text: "Calibration"
  end
end

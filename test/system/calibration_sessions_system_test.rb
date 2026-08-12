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

  # Evidence linked to a person's at-level cell — what the wall reads.
  def back_evidence(person, author, capability, content, valence)
    item = create(:evidence_item, tenant: @tenant, with_link: false,
                  person_id: person.id, author: author,
                  framework_id: @cycle.framework_id,
                  capability_stable_id: capability.stable_id, level_ordinal: 3,
                  content: content)
    EvidenceLink.create!(
      tenant_id: @tenant.id, evidence_id: item.id, person_id: person.id,
      framework_id: @cycle.framework_id, capability_stable_id: capability.stable_id,
      level_ordinal: 3, link_status: "active", linked_by_id: author.id,
      linked_at: item.recorded_at, valence: valence
    )
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

    click_button_with_js_fallback "Create draft session", expect_text: "Calibration session created"

    # Draft page: seeded population grouped by rater, readiness surfaced
    assert_text "Calibration session created"
    assert_text "Engineering calibration"
    assert_text "Mia Manager's reports (1)"
    assert_text "Ivy IC"
    assert_text "Omar IC"
    assert_text "0 of 2 manager-rated"
    assert_text "not enrolled in the cycle"

    # Remove a calibrant — they surface as an explicit re-add suggestion
    page.execute_script("document.querySelector(\"button[aria-label='Remove Ivy IC from the population']\").click()")
    assert_text "Removed from the population."
    assert_text "Reporting to participants but not in the population:"
    within(".border-dashed") { assert_text "Ivy IC" }

    # Re-add via the suggestion affordance
    page.execute_script("document.querySelector(\"button[aria-label='Add Ivy IC to the population']\").click()")
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
      # A scorable ladder so the cohort tab has real numbers: role, levels,
      # and both capabilities bound. Adds nothing to the strip/board math.
      family = create(:framework_role_family, tenant: @tenant, framework_id: @cycle.framework_id)
      engineer = create(:framework_role, tenant: @tenant, role_family_id: family.role_family_id)
      (1..5).each { |o| create(:framework_level, tenant: @tenant, role_id: engineer.role_id, ordinal: o) }

      category = create(:framework_capability_category, tenant: @tenant,
                        framework_id: @cycle.framework_id, name: "Thinking")
      @cap_a = create(:framework_capability, tenant: @tenant,
                      category_id: category.category_id, name: "Strategic Thinking")
      cap_b = create(:framework_capability, tenant: @tenant,
                     category_id: category.category_id, name: "Delivery")

      report_3 = create(:person, tenant: @tenant, name: "Nia IC", manager: @em_1)
      @report_3_id = report_3.id
      report_4 = create(:person, tenant: @tenant, name: "Pax IC", manager: @em_2)
      population = [ @report_1, @report_2, report_3, report_4 ]
      # report_1/2 already hold assignments from setup (DeterministicId PK).
      [ report_3, report_4 ].each do |person|
        create(:person_framework_assignment, tenant: @tenant,
               person_id: person.id, framework_id: @cycle.framework_id, role_id: engineer.role_id)
      end
      PersonFrameworkAssignment.where(person_id: [ @report_1.id, @report_2.id ])
        .update_all(role_id: engineer.role_id)
      population.each do |person|
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: person.id, level_ordinal: 3, role_id: engineer.role_id)
      end
      [ @cap_a, cap_b ].each do |cap|
        create(:framework_capability_role_binding, tenant: @tenant,
               capability_id: cap.capability_id, role_id: engineer.role_id)
        create(:framework_behavioural_expectation, tenant: @tenant,
               capability_id: cap.capability_id, level_ordinal: 3)
      end
      # Mia rates high, Raj rates low on Strategic Thinking; both agree on Delivery.
      rate(@report_1, @cap_a, "consistent")
      rate(report_3, @cap_a, "consistent")
      rate(@report_2, @cap_a, "none")
      rate(report_4, @cap_a, "none")
      rate(@report_1, cap_b, "occasional")
      rate(@report_2, cap_b, "occasional")

      # One of Mia's ratings is carried forward, unconfirmed this cycle — the
      # surfaces must say so rather than presenting it as a fresh judgment.
      AssessmentLevelRating
        .find_by(cycle_id: @cycle.cycle_id, person_id: report_3.id,
                 capability_stable_id: @cap_a.stable_id)
        .update!(manager_rating_source: "seeded")

      # A rater with NOTHING rated: keeps a strip row (as a sentence, not
      # zeroed columns), stays off the board's legend, and collapses to one
      # line on the drill-in grid. Adds zero cells, so no aggregate below
      # moves.
      quinn = create(:person, tenant: @tenant, name: "Quinn Alderberry", manager: @facilitator)
      pax = create(:person, tenant: @tenant, name: "Pax Thistledown", manager: quinn)
      create(:person_framework_assignment, tenant: @tenant,
             person_id: pax.id, framework_id: @cycle.framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: pax.id, level_ordinal: 3)
      @quinn_id = quinn.id
      @pax_id = pax.id

      # Near-identical evidence under divergent ratings — the wall's money shot.
      back_evidence(@report_1, @em_1, @cap_a, "Ran the pricing spike end to end.", "demonstrated")
      back_evidence(@report_2, @em_2, @cap_a, "Ran the billing spike end to end.", "growth_area")

      ctx = AuthorizationContext.new(
        user: @facilitator_user,
        tenant_user: TenantUser.find_by(user: @facilitator_user),
        person: @facilitator
      )
      result = Operations::CalibrationSessions::Define.call(
        context: ctx,
        params: {
          cycle_id: @cycle.cycle_id, name: "Live calibration",
          participant_ids: [ @em_1.id, @em_2.id, @quinn_id ],
          calibrant_person_ids: population.map(&:id) + [ @pax_id ]
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
    # ── Strip content, on the default tab ──
    assert_selector "a[role='tab'][aria-selected='true']", text: "Rater tendency"
    assert_no_text "CAPABILITY DIVERGENCE"
    # Carried-forward values are marked, not hidden and not excluded.
    assert_text "Carried"
    # Mia has 3 at-level cells; 1 of them is carried.
    assert_text "1 of 3"
    # The silent rater: a sentence, never zeroed columns.
    assert_text "No ratings yet — not counted in the org mean or any column."
    # No curation affordances on a live session
    assert_no_text "Add person from your org"

    # ── Tabs: one pane at a time, swapped in place ──
    # A sentinel that survives frame swaps but not full navigations — the
    # whole point of the pane frame is that a tab click doesn't reload (or
    # scroll) the page.
    page.execute_script("window.__staying = true")
    click_with_retry(expect_text: "CAPABILITY DIVERGENCE") { click_link "Capability divergence" }
    assert_text "Strategic Thinking"
    assert_text "spread 3.0"
    assert_text "raters disagree"
    # The capability comparison spans all 4 raters' cells on it.
    assert_text "1 of 4 carried"
    # …and the silent rater is a footnote here, not a legend colour with no
    # dot behind it. One pane at a time: the strip is gone.
    assert_text "Quinn Alderberry hasn't rated yet — not on the board."
    assert_no_text "RATER TENDENCY"

    # ── Score by cohort ──
    # JS-dispatched so Selenium's scroll-into-view can't touch scrollY, and
    # in a SHORT viewport so the fixture page actually scrolls: the frame
    # swap must leave the room's scroll position alone — the entire reason
    # the tabs live in a pane frame.
    page.driver.browser.manage.window.resize_to(1400, 500)
    page.execute_script("window.scrollTo(0, 300)")
    assert_operator page.evaluate_script("window.scrollY"), :>=, 300,
                    "the instrument needs a page that scrolls"
    click_with_retry(expect_text: "SCORE BY COHORT") do
      page.execute_script(<<~JS)
        [...document.querySelectorAll("a[role='tab']")]
          .find((a) => a.textContent.includes("Score by cohort")).click()
      JS
    end
    assert page.evaluate_script("window.__staying === true"),
           "tab clicks must swap the pane frame, never reload the page"
    assert_operator page.evaluate_script("window.scrollY"), :>=, 200,
                    "the swap must not scroll the room back to the top"
    page.driver.browser.manage.window.resize_to(1400, 1400)
    assert_equal "cohort", URI.parse(current_url).then { |u| Rack::Utils.parse_query(u.query)["view"] },
                 "the tab is shareable — pushState carries ?view="
    assert_text "100% — meets expectations"
    assert_text "median"
    # All four L3 people scored (each has ≥1 of 2 at-level cells rated).
    assert_selector "a[aria-label*='% of expected']", count: 4

    # Open a dot → the comparison drawer, with the rater-context reframe.
    # JS-fallback: the fixed drawer can intercept pointer clicks near the
    # viewport bottom (the drop class the helpers exist for).
    click_selector_with_js_fallback("a[aria-label^='Nia IC']",
                                    expect_text: "rated by Mia Manager")
    assert page.evaluate_script("window.__staying === true"),
           "a dot click swaps the pane too — no scroll jump mid-discussion"
    assert_selector "#calibration-comparison-drawer [data-drawer-card]"
    assert_text "of expected"
    assert_text "vs org mean"

    # Pin Nia, open another dot — both cards hold side by side, and the
    # pin survives a tab switch (it rides every overview link).
    nia_id = page.find("#calibration-comparison-drawer [data-drawer-card]")["data-drawer-card"]
    click_link_with_js_fallback("Pin", expect_selector: "a[aria-label^='Unpin']")
    click_selector_with_js_fallback(
      "a[aria-label*='% of expected']:not([aria-label^='Nia IC'])",
      expect_selector: "[data-drawer-card]:not([data-drawer-card='#{nia_id}'])"
    )
    assert_selector "#calibration-comparison-drawer [data-drawer-card]", count: 2
    click_link_with_js_fallback("Rater tendency", expect_text: "RATER TENDENCY")
    assert_selector "[data-drawer-card='#{nia_id}']", count: 1
    click_link_with_js_fallback("Score by cohort", expect_text: "SCORE BY COHORT")

    # The drawer composes with the drill-in rather than growing a grid —
    # and the pins ride along into it.
    assert_selector "a[href*='capabilities'][href*='person=']", minimum: 1
    click_with_retry(expect_text: "AT-LEVEL RATINGS BY RATER") do
      find("a[href*='capabilities'][href*='person=']", match: :first).click
    end
    assert_includes page.current_url, "pins%5B%5D=#{nia_id}"
    assert_selector "[data-drawer-card='#{nia_id}']"

    # ── The cohort axis on a phone: scrolls inside its own container ──
    page.driver.browser.manage.window.resize_to(375, 812)
    visit calibration_session_path(@live_session_id, view: "cohort")
    assert_text "SCORE BY COHORT"
    overflowing = page.evaluate_script(<<~JS)
      (() => {
        const wrap = document.querySelector(".overflow-x-auto");
        return wrap.scrollWidth > wrap.clientWidth &&
               document.documentElement.scrollWidth <= window.innerWidth + 1;
      })()
    JS
    assert overflowing, "the axis scrolls inside its wrapper, never the page body"
    # A dot is still reachable after scrolling the wrapper.
    page.execute_script(<<~JS)
      const wrap = document.querySelector(".overflow-x-auto");
      wrap.scrollLeft = wrap.scrollWidth;
      [...wrap.querySelectorAll("a[aria-label*='% of expected']")].at(-1).click();
    JS
    assert_text "rated by"
    page.driver.browser.manage.window.resize_to(1400, 1400)

    # Back to the session page for the rest of the flow — a deep link to
    # the cohort tab renders it directly (the ?view= param is shareable),
    # then over to the strip for the vocabulary check.
    visit calibration_session_path(@live_session_id, view: "cohort")
    assert_text "SCORE BY COHORT"
    click_with_retry(expect_text: "RATER TENDENCY") { click_link "Rater tendency" }

    # ── The vocabulary defines itself, by KEYBOARD ──
    # The room is on a projector and the facilitator may be driving by
    # keyboard, so a hover-only definition reaches nobody. Focus the term
    # and the panel must appear.
    wait_for_stimulus "definition-tip"
    tip = find("button[aria-describedby='calibration-term-self-gap']")
    assert_no_selector "#calibration-term-self-gap", visible: true
    tip.send_keys("")   # focus without clicking
    assert_selector "#calibration-term-self-gap", visible: true,
                    text: /both sides rated/

    # …and the panel must be readable, not sliced off by the tendency
    # table's horizontal scroll. It rides the top layer for exactly this.
    clipped = page.evaluate_script(<<~JS)
      (() => {
        const p = document.getElementById("calibration-term-self-gap");
        const r = p.getBoundingClientRect();
        return r.right > window.innerWidth || r.left < 0 || r.width < 100;
      })()
    JS
    assert_not clipped, "the definition must not be clipped by a scrolling ancestor"
    # NOTE: the controller also flips the panel above a term with no room
    # below it. That path is deliberately NOT asserted here — this fixture's
    # strip is too short to put a term at the fold, and every contrivance
    # that forced one (short viewport, scrollIntoView) still left room below,
    # so the assertion passed with the flip removed. A test that cannot fail
    # is worse than none; the flip is verified visually instead.

    # ── Drill-in: divergence row → rater × level grid ──
    click_with_retry(expect_text: "CAPABILITY DIVERGENCE") { click_link "Capability divergence" }
    click_link_with_js_fallback("Strategic Thinking", expect_text: "AT-LEVEL RATINGS BY RATER")
    assert_text "AT-LEVEL RATINGS BY RATER"
    assert_selector "a[data-person-id]", minimum: 4
    # …and on the grid, the silent rater collapses to one sentence — with
    # their people as links, so the person card (and its revisit ask) stays
    # reachable for exactly the unrated cell the room will ask about.
    assert_text "Quinn Alderberry hasn't rated this capability yet"
    click_selector_with_js_fallback("a[data-person-id='#{@pax_id}']",
                                    expect_selector: "#calibration-person-card")
    assert_text "Pax Thistledown"
    # The carried dot wears the dashed edge and says so non-visually.
    carried_dot = find("a[data-person-id='#{@report_3_id}']")
    assert_includes carried_dot["aria-label"], "carried forward from the previous cycle"
    assert_selector "a[data-person-id='#{@report_3_id}'] span.border-dashed"

    # The dot is initialled for compactness and named for everyone else.
    dot = find("a[data-person-id='#{@report_1.id}']")
    assert_equal "II", dot.text.strip, "dots carry the ratee's initials"
    assert_equal "Ivy IC", dot["title"]
    assert dot["aria-label"].start_with?("Ivy IC —"),
      "the accessible name carries the person, not just their initials"

    # Opening a dot shows their card.
    click_selector_with_js_fallback("a[data-person-id='#{@report_1.id}']",
                                    expect_selector: "#calibration-person-card")
    assert_text "Ivy IC"
    assert_text "Manager: Consistently"

    # ── The pane swaps in place: the room keeps its scroll position ──
    # A full-page navigation would scroll back to the top, hiding the very
    # card that was just opened. Shrink the window first so the drill-in
    # actually overflows — on a tall window scrollY is 0 either way and the
    # assertion could never fail.
    # Anchor mid-page, not at the bottom: the panes differ slightly in
    # height, and a bottom-anchored scroll gets clamped by that difference.
    page.driver.browser.manage.window.resize_to(1000, 600)
    page.execute_script("window.scrollTo(0, 300)")
    scrolled = page.evaluate_script("window.scrollY")
    # The exact resting point tracks page height (it shrank when the
    # standalone expectations card folded away) — any real scroll works.
    assert_operator scrolled, :>, 100, "precondition: the page must be scrollable to test this"

    # JS-dispatched on purpose: a pointer click would scroll the link into
    # view first (Selenium mechanics), which is exactly the movement this
    # step exists to rule out for the SWAP itself.
    page.execute_script(<<~JS)
      [...document.querySelectorAll("a")]
        .find((a) => a.textContent.includes("Feedback / Evidence wall")).click()
    JS
    assert_text "2 items"
    assert_equal scrolled, page.evaluate_script("window.scrollY"),
      "switching panes must not move the page"
    # …and the URL still carries the pane, so the view stays shareable.
    assert_includes page.current_url, "view=wall"
    page.driver.browser.manage.window.resize_to(1400, 1400)
    # Every item names its person and shows what was written — the room
    # compares near-identical evidence under divergent ratings.
    assert_text "Ran the pricing spike end to end."
    assert_text "Ran the billing spike end to end."
    assert_text "Ivy IC"
    assert_text "Omar IC"

    # Filtering narrows the wall.
    page.execute_script(<<~JS)
      const select = document.querySelector("#wall-filter-wall_valence")
      select.value = "growth_area"
      select.form.requestSubmit()
    JS
    assert_text "1 item"
    # Scoped to the WALL — the same evidence legitimately shows on Ivy's
    # open drawer card, which wall filters must not touch.
    within("#calibration-wall") { assert_no_text "Ran the pricing spike end to end." }

    # The filter rides every pane link, so clear it before moving on.
    page.execute_script(<<~JS)
      const select = document.querySelector("#wall-filter-wall_valence")
      select.value = ""
      select.form.requestSubmit()
    JS
    assert_text "2 items"

    # ── Comparison drawer: pinning holds two cards side by side ──
    click_selector_with_js_fallback("a[data-person-id='#{@report_1.id}']",
                                    expect_text: "Manager: Consistently")
    click_link_with_js_fallback(
      "Pin", expect_selector: "[data-drawer-card='#{@report_1.id}'] a[aria-label^='Unpin']"
    )
    assert_selector "[data-drawer-card='#{@report_1.id}']"
    assert_text "Ran the pricing spike end to end."

    # Open the second person — the pinned card stays put beside the
    # inspector, so the room reads both at once.
    click_selector_with_js_fallback("a[data-person-id='#{@report_2.id}']",
                                    expect_text: "Omar IC")
    assert_selector "[data-drawer-card='#{@report_1.id}']"
    assert_selector "[data-drawer-card='#{@report_2.id}']"
    click_link_with_js_fallback(
      "Pin", expect_selector: "[data-drawer-card='#{@report_2.id}'] a[aria-label^='Unpin']"
    )
    assert_text "Ran the billing spike end to end."

    # Unpinning releases the slot (the card re-offers Pin).
    click_selector_with_js_fallback(
      "[data-drawer-card='#{@report_2.id}'] a[aria-label^='Unpin']",
      expect_selector: "[data-drawer-card='#{@report_2.id}'] a[aria-label^='Pin ']"
    )
    # Still open as the inspector — and genuinely unpinned: the violet
    # ring is gone and Pin is offered again.
    assert_selector "[data-drawer-card='#{@report_2.id}'] a", text: "Pin"
    assert_no_selector "[data-drawer-card='#{@report_2.id}'] a[aria-label^='Unpin']"
  end

  test "facilitator flags an unclear expectation from the drill-in" do
    ActsAsTenant.with_tenant(@tenant) do
      # The flag raises a framework clarification, so this framework needs a
      # real event stream — built through commands, not read-model factories.
      fw_id = SecureRandom.uuid_v7
      cap_stable = SecureRandom.uuid_v7
      cap_id = SecureRandom.uuid_v7
      role_id = SecureRandom.uuid_v7
      level_id = SecureRandom.uuid_v7
      handler = Frameworks::CommandHandler.new
      handler.create_framework(fw_id, "Eng Framework")
      rfid = SecureRandom.uuid_v7
      handler.add_role_family(fw_id, rfid, "Engineering")
      handler.add_role(fw_id, role_id, rfid, "Software Engineer", "E", "ic")
      handler.add_level(fw_id, level_id, role_id, 3, "Engineer III", "E3")
      handler.add_level(fw_id, SecureRandom.uuid_v7, role_id, 4, "Engineer IV", "E4")
      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(fw_id, cat_id, "Thinking")
      handler.add_capability(fw_id, cap_id, cap_stable, cat_id, "Strategic Thinking")
      exp3_id = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(fw_id, exp3_id, SecureRandom.uuid_v7,
                                          cap_id, 3, "Shapes team direction")
      handler.set_behavioural_expectation(fw_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                          cap_id, 4, "Shapes system direction")
      handler.add_role_illustration(fw_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7,
                                    exp3_id, role_id, 1, "Runs the team retro end to end")
      handler.publish_version(fw_id, "test")

      # A real PD assignment (not a factory row) — the revisit mirror lands on
      # this stream and its aggregate requires the person to be assigned.
      # Assigned BEFORE the cycle row exists so AutoEnrollNewAssignments
      # doesn't try to enroll into a factory cycle with no event stream.
      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
        PersonDevelopment::CommandHandler.new.assign_to_framework(@report_1.id, fw_id, role_id, level_id)
      end
      cycle = create(:assessment_cycle, tenant: @tenant, name: "H2 2026 Review", framework_id: fw_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: cycle,
             person_id: @report_1.id, level_ordinal: 3, role_id: role_id)
      # Rated ABOVE the assessed level — the person card's ladder must
      # surface it (at-level stays unrated, so the grid's unrated-rater
      # sentence is untouched).
      create(:assessment_level_rating, tenant: @tenant, cycle_id: cycle.cycle_id,
             person_id: @report_1.id, framework_id: fw_id,
             capability_stable_id: cap_stable, level_ordinal: 4,
             manager_rated_frequency: "occasional")

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
      @flag_framework_id = fw_id
    end

    sign_in_as(@facilitator_user)
    visit calibration_session_capability_path(@flag_session_id, @flag_cap_stable)
    assert_text "AT-LEVEL RATINGS BY RATER"

    # "What good looks like" lives in the level column's ⓘ menu now —
    # expectation, examples, and the ⚑ flags, anchored to the column.
    open_dropdown(scope: "th[data-level-menu='3']")
    assert_text "Shapes team direction"
    assert_text "Runs the team retro end to end"

    # Raise the cell clarification from the menu (native <details> — set
    # .open directly; a synthetic summary click can be dropped on CI).
    assert_selector "summary", text: "⚑ Flag expectation as unclear"
    page.execute_script(<<~JS)
      document.querySelectorAll("details > summary").forEach((s) => {
        if (s.textContent.includes("Flag expectation")) s.parentElement.open = true
      })
    JS
    js_set_field "#flag-reason-3", "Scope or altitude?"
    click_button_with_js_fallback "Raise clarification", expect_text: "clarification discussion is now open"

    # One flag per cell per session: the marker replaces the affordance.
    open_dropdown(scope: "th[data-level-menu='3']")
    assert_text "⚑ Flagged — 1 open clarification on the framework"
    assert_no_selector "summary", text: "⚑ Flag expectation as unclear"

    # ── An EXAMPLE is flaggable on its own — narrower than the cell ──
    page.execute_script(<<~JS)
      document.querySelectorAll("details > summary").forEach((s) => {
        if (s.textContent.includes("Flag example")) s.parentElement.open = true
      })
    JS
    js_set_field "textarea[aria-label^='Why this example is unclear']", "Reads as an L5 behaviour"
    click_button_with_js_fallback "Flag example", expect_text: "Example flagged"
    open_dropdown(scope: "th[data-level-menu='3']")
    assert_text "⚑ Example flagged — clarification open on the framework"
    ActsAsTenant.with_tenant(@tenant) do
      example_flag = FrameworkState::SuggestedEdit.clarifications.pending
        .find_by!(target_entity_type: "role_illustration")
      assert_includes example_flag.rationale, "Reads as an L5 behaviour"
    end

    ActsAsTenant.with_tenant(@tenant) do
      clarification = FrameworkState::SuggestedEdit.clarifications.pending
        .where(target_entity_type: "behavioural_expectation").sole
      assert_includes clarification.rationale, "Flagged during Flag calibration"
      assert_includes clarification.rationale, "Scope or altitude?"
      flags = CalibrationSessions::SessionOutcomes.new(session: CalibrationSession.find(@flag_session_id)).flags
      assert_equal clarification.suggestion_id, flags.first[:suggestion_id]
    end

    # ── Ask the rater to revisit, from the person card ──
    # This dot click dropped TWICE through click_with_retry on a starved CI
    # runner (both attempts share Selenium's pointer mechanism) — the
    # JS-fallback guarantees the second attempt fires.
    click_selector_with_js_fallback("a[data-person-id='#{@report_1.id}']",
                                    expect_selector: "#calibration-person-card")
    assert_text "Ivy IC"

    # ── Mobile: the drawer scrolls its cards internally, never the page ──
    page.driver.browser.manage.window.resize_to(375, 812)
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1"),
           "the drawer must not widen the page on mobile"
    page.driver.browser.manage.window.resize_to(1400, 1400)

    # ── The read-only ladder: the E4 chip swaps the panel to the
    # above-level cell in place (pane frame, no scroll jump) ──
    click_selector_with_js_fallback(
      "#calibration-person-card a[href*='person_level=4']",
      expect_selector: "#calibration-person-card a[aria-current='true'][href*='person_level=4']"
    )
    assert_text "Shapes system direction"
    assert_text "Manager: Most of the time"
    # …and back to the assessed level before the asks below, so they scope
    # to the L3 cell the room is discussing.
    click_selector_with_js_fallback(
      "#calibration-person-card a[href*='person_level=3']",
      expect_selector: "#calibration-person-card a[aria-current='true'][href*='person_level=3']"
    )

    # ── The drawer resizes by its top handle; dragging into the bottom
    # 20px closes it, the slim bar expands it back ──
    before = page.evaluate_script("document.querySelector(\"[data-comparison-drawer-target='body']\").offsetHeight")
    page.execute_script(<<~JS)
      const handle = document.querySelector("[data-comparison-drawer-target='handle']")
      handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, clientY: window.innerHeight - 300 }))
      window.dispatchEvent(new PointerEvent("pointermove", { clientY: window.innerHeight - 700 }))
      window.dispatchEvent(new PointerEvent("pointerup", {}))
    JS
    after = page.evaluate_script("document.querySelector(\"[data-comparison-drawer-target='body']\").offsetHeight")
    assert_operator after, :>, before + 100, "dragging the handle up grows the card row"

    # The separator resizes from the keyboard too, and reports its value.
    page.execute_script(<<~JS)
      const handle = document.querySelector("[data-comparison-drawer-target='handle']")
      handle.focus()
      handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true }))
    JS
    keyed = page.evaluate_script("document.querySelector(\"[data-comparison-drawer-target='body']\").offsetHeight")
    assert_equal after + 24, keyed, "ArrowUp on the handle grows the row one step"
    assert_equal keyed.to_s,
                 page.find("[data-comparison-drawer-target='handle']", visible: :all)["aria-valuenow"],
                 "the separator reports its size"

    page.execute_script(<<~JS)
      const handle = document.querySelector("[data-comparison-drawer-target='handle']")
      handle.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, clientY: window.innerHeight - 400 }))
      window.dispatchEvent(new PointerEvent("pointermove", { clientY: window.innerHeight - 10 }))
    JS
    assert_selector "[data-comparison-drawer-target='expandBar']", visible: true
    assert_selector "[data-comparison-drawer-target='body']", visible: :hidden
    page.execute_script("document.querySelector(\"[data-comparison-drawer-target='expandBar']\").click()")
    assert_selector "#calibration-person-card", visible: true

    # The ask lives in the card's kebab; the item swaps the form in via the
    # pane frame (URL-driven, no scroll jump).
    open_dropdown(scope: "#calibration-person-card")
    click_link_with_js_fallback "revisit this rating…",
                                expect_text: "to revisit this rating at L"
    js_set_field "#revisit-note", "Compare against the two peers we just discussed"
    click_button_with_js_fallback "Request revisit", expect_text: "Revisit requested"

    # One ask per cell per session — the marker replaces the kebab item.
    assert_text "Revisit requested — it will appear in Mia Manager's assessment activity."
    assert_no_selector "a", text: /revisit this rating…/

    ActsAsTenant.with_tenant(@tenant) do
      revisits = CalibrationSessions::SessionOutcomes
        .new(session: CalibrationSession.find(@flag_session_id)).revisit_requests
      assert_equal [ @report_1.id ], revisits.map { |r| r[:person_id] }
      assert_equal "Compare against the two peers we just discussed", revisits.first[:note]

      mirrored = Rails.configuration.event_store.read
        .stream(EventStreamNaming.person_development_stream(@report_1.id, @flag_framework_id))
        .to_a.select { |e| e.is_a?(PersonDevelopment::Events::RatingRevisitRequested) }
      assert_equal 1, mirrored.size, "the nudge must mirror onto the person's PD stream"
    end

    # ── §f: request feedback / evidence from the person card's kebab ──
    # The redirect re-opened Ivy's card (person= rides the return path).
    assert_text "Ivy IC"
    open_dropdown(scope: "#calibration-person-card")
    click_link_with_js_fallback "Request feedback / evidence…",
                                expect_text: "Request feedback / evidence about Ivy IC"
    page.execute_script(<<~JS)
      const select = document.querySelector("#evidence-request-requestee")
      select.value = [...select.options].find((o) => o.text.includes("Mia Manager")).value
    JS
    js_set_field "#evidence-request-message", "Nobody could answer what good looks like here"
    click_button_with_js_fallback "Send request", expect_text: "Feedback / evidence requested"

    ActsAsTenant.with_tenant(@tenant) do
      request = EvidenceRequest.sole
      assert_equal @em_1.id, request.requestee_person_id
      assert_equal @report_1.id, request.person_id
      recorded = CalibrationSessions::SessionOutcomes
        .new(session: CalibrationSession.find(@flag_session_id)).evidence_requests
      assert_equal [ request.id ], recorded.map { |r| r[:request_id] }
    end

    # An outcome opens the log, so the entry it just wrote is visible even if
    # the room had the panel collapsed — the rule the note composer follows.
    assert_selector "#calibration-log-pane[data-pane-state='open']"
    assert_text "Asked Mia Manager to revisit a rating"
    assert_text "Asked Mia Manager for feedback / evidence"
    assert_text "Awaiting response"
    assert_selector "button", text: "Requests"

    # ── The log rides the drill-in as a side panel ──
    # Closed by default here (the grid wants the width), and it survives a
    # pane switch — the whole point of a side panel. Clear the cookie AND
    # re-enter by the bare path, so this asserts the SURFACE's default
    # rather than a preference set earlier or the outcome's `activity=open`.
    page.execute_script(<<~JS)
      document.cookie = "calibration_drill_in_log_pane_open=; path=/; max-age=0"
      document.cookie = "calibration_log_pane_open=; path=/; max-age=0"
    JS
    visit calibration_session_capability_path(@flag_session_id, @flag_cap_stable)
    assert_selector "#calibration-log-pane[data-pane-state='closed']", visible: :all
    page.execute_script(
      %{document.querySelector("[data-action*='activity-pane#toggle']").click()}
    )
    assert_selector "#calibration-log-pane[data-pane-state='open']"
    assert_text "⚑ Flagged an expectation as unclear"

    # Heading renders through CSS `uppercase`, so assert the rendered case.
    click_link_with_js_fallback("Feedback / Evidence wall", expect_text: "FEEDBACK / EVIDENCE —")
    assert_selector "#calibration-log-pane[data-pane-state='open']"
    assert_text "⚑ Flagged an expectation as unclear"

    # ── The session page is the follow-through artifact ──
    # One reverse-chronological feed in the product's activity form: summary,
    # live status, context line, the room's own words. Open by default here.
    visit calibration_session_path(@flag_session_id)
    assert_selector "#calibration-log-pane[data-pane-state='open']"
    assert_text "SESSION LOG"
    assert_text "⚑ Flagged an expectation as unclear"
    assert_text "Discussion open"
    assert_text "Strategic Thinking · L3"
    assert_text "Asked Mia Manager to revisit a rating"
    assert_text "Open"
    assert_text "Ivy IC · Strategic Thinking · L3"
    assert_text "Compare against the two peers we just discussed"
    assert_text "Asked Mia Manager for feedback / evidence"
    assert_text "Awaiting response"
    # Newest first — flag, then revisit, then the feedback request.
    entries = all("[data-framework-activity-target='entry']").map(&:text)
    assert_match(/feedback \/ evidence/, entries.first)
    assert_match(/revisit a rating/, entries[1])
    assert_match(/Flagged an expectation/, entries.last)

    js_set_field "#session-note", "Add the two reference ICs to the org-wide session"
    click_button_with_js_fallback "Record note", expect_text: "Note recorded."
    assert_text "Add the two reference ICs to the org-wide session"

    # A note recorded from the DRILL-IN stays on the drill-in and carries
    # the capability it was about — the panel exists so the room doesn't
    # get yanked out of the discussion.
    # `activity=open` wins over the cookie, so this doesn't depend on
    # whatever state the toggling above left behind.
    visit calibration_session_capability_path(@flag_session_id, @flag_cap_stable, activity: "open")
    assert_selector "#calibration-log-pane[data-pane-state='open']"
    js_set_field "#session-note", "Ratings here look a level high"
    click_button_with_js_fallback "Record note", expect_text: "Note recorded."
    assert_current_path(/capabilities/)
    assert_text "Ratings here look a level high"
    assert_text "Strategic Thinking"

    visit calibration_session_path(@flag_session_id)

    # The chips narrow the feed client-side, like every other activity panel.
    page.execute_script(
      %{document.querySelector("[data-framework-activity-filter-param='notes']").click()}
    )
    assert_text "Add the two reference ICs to the org-wide session"
    assert_no_text "⚑ Flagged an expectation as unclear"
  end

  # Sets a field's value via JS + input/change events — these values feed
  # exact-match assertions, and Selenium send_keys drops characters on
  # starved CI runners (see docs/guidelines/testing.md).
  def js_set_field(selector, value)
    el = find(selector)
    page.execute_script(<<~JS, el, value)
      const el = arguments[0];
      el.value = arguments[1];
      el.dispatchEvent(new Event("input", { bubbles: true }));
      el.dispatchEvent(new Event("change", { bubbles: true }));
    JS
  end

  test "calibration screens use the full width of a large desktop" do
    session_id = nil
    ActsAsTenant.with_tenant(@tenant) do
      ctx = AuthorizationContext.new(
        user: @facilitator_user,
        tenant_user: TenantUser.find_by(user: @facilitator_user),
        person: @facilitator
      )
      result = Operations::CalibrationSessions::Define.call(
        context: ctx,
        params: {
          cycle_id: @cycle.cycle_id, name: "Wide calibration",
          participant_ids: [ @em_1.id ],
          calibrant_person_ids: [ @report_1.id ]
        }
      )
      Operations::CalibrationSessions::Start.call(context: ctx, params: { session_id: result[:session_id] })
      session_id = result[:session_id]
    end

    page.driver.browser.manage.window.resize_to(2400, 1100)
    sign_in_as(@facilitator_user)

    visit calibration_sessions_path
    assert_text "Wide calibration"
    # Binary guard: a w-full wrapper measures ~1.0 by construction — this
    # exists to fail if a max-w-* cap ever comes back.
    assert_operator width_ratio, :>=, 0.95,
                    "the index must not sit in a narrow column on a big screen"

    visit calibration_session_path(session_id)
    assert_text "RATER TENDENCY"
    assert_operator width_ratio, :>=, 0.95,
                    "the session room must not sit in a narrow column on a big screen"
  end

  # The page wrapper's share of the viewport — the calibration screens
  # use the full desktop width (the comparison-drawer design needs it).
  def width_ratio
    page.evaluate_script(
      "document.querySelector('#main-content > div').getBoundingClientRect().width / window.innerWidth"
    )
  end

  test "member without reports sees no Calibration nav link" do
    sign_in_as(@member_user)

    assert_text "Home"
    assert_no_selector "a", text: "Calibration"
  end
end

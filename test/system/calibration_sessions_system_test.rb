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
           manager_rated_frequency: frequency, last_manager_rated_at: Time.current)
  end

  # A started session over two raters with one report each, both enrolled at
  # L3 on a two-capability ladder; only Ivy's first capability is rated, so
  # readiness opens at 1 of 4 cells.
  def live_session_with_ladder
    ActsAsTenant.with_tenant(@tenant) do
      family = create(:framework_role_family, tenant: @tenant, framework_id: @cycle.framework_id)
      engineer = create(:framework_role, tenant: @tenant, role_family_id: family.role_family_id)
      (1..5).each { |o| create(:framework_level, tenant: @tenant, role_id: engineer.role_id, ordinal: o) }
      category = create(:framework_capability_category, tenant: @tenant,
                        framework_id: @cycle.framework_id, name: "Thinking")
      @cap_a = create(:framework_capability, tenant: @tenant, category_id: category.category_id, name: "Strategic Thinking")
      @cap_b = create(:framework_capability, tenant: @tenant, category_id: category.category_id, name: "Delivery")
      [ @cap_a, @cap_b ].each do |cap|
        create(:framework_capability_role_binding, tenant: @tenant,
               capability_id: cap.capability_id, role_id: engineer.role_id)
        create(:framework_behavioural_expectation, tenant: @tenant,
               capability_id: cap.capability_id, level_ordinal: 3)
      end
      PersonFrameworkAssignment.where(person_id: [ @report_1.id, @report_2.id ]).update_all(role_id: engineer.role_id)
      [ @report_1, @report_2 ].each do |person|
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: person.id, level_ordinal: 3, role_id: engineer.role_id)
      end
      rate(@report_1, @cap_a, "consistent")

      ctx = AuthorizationContext.new(
        user: @facilitator_user, tenant_user: TenantUser.find_by(user: @facilitator_user), person: @facilitator
      )
      result = Operations::CalibrationSessions::Define.call(
        context: ctx,
        params: { cycle_id: @cycle.cycle_id, name: "Live readiness",
                  participant_ids: [ @em_1.id, @em_2.id ],
                  calibrant_person_ids: [ @report_1.id, @report_2.id ] }
      )
      Operations::CalibrationSessions::Start.call(context: ctx, params: { session_id: result[:session_id] })
      @live_session_id = result[:session_id]
    end
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

    js_fill_in "Session name", with: "Engineering calibration"
    select "H1 2026 Review", from: "Assessment cycle"

    # Pick raters via the shared person picker: one from the quick-add
    # suggestions, one through the typeahead search. Stimulus-action
    # buttons are JS-dispatched per the flake guards.
    wait_for_stimulus "person-picker"
    page.execute_script(
      %{document.querySelector("[data-person-picker-target='suggestions'] [data-person-picker-person-id-param='#{@em_1.id}']").click()}
    )
    assert_selector "[data-person-picker-target='selected'] span[data-person-id='#{@em_1.id}']", text: "Mia Manager"

    # The debounced typeahead searches for this exact string — a dropped
    # keystroke queries "Ra" and the candidate frame comes back empty.
    js_fill_in "Participants (raters)", with: "Raj"
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
    # Readiness is cell coverage; nobody is enrolled yet, so there are no
    # cells to rate and nobody is fully rated.
    assert_text "0 of 2 people fully rated"
    assert_text "Draft · ratings as of"
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
    assert_text "Live · ratings as of"
    # The header carries the live state; the stale "frozen … coming next"
    # sentence read as "the numbers are frozen".
    assert_no_text "coming next"
    assert_no_selector "button[aria-label='Remove Ivy IC from the population']"
    assert_no_text "Add person from your org"
  end

  # A live session: Mia rates Strategic Thinking high, Raj low, both agree on
  # Delivery; Quinn has rated nothing. `with_unrated:` adds a report of
  # Mia's she hasn't rated yet, so the drill-in has someone off the axis.
  def seed_live_session(with_unrated: false)
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
      if with_unrated
        uma = create(:person, tenant: @tenant, name: "Uma IC", manager: @em_1)
        create(:person_framework_assignment, tenant: @tenant,
               person_id: uma.id, framework_id: @cycle.framework_id, role_id: engineer.role_id)
        @uma_id = uma.id
        population << uma
      end
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
  end

  test "facilitator sees tendency strip and divergence board on a live session" do
    seed_live_session

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
    # Carried-forward values are marked, not hidden and not excluded: Mia's
    # n is 3 rated cells, 1 of them carried.
    assert_text "33% carried"
    # Readiness lives on its own card; the strip keeps only bias columns.
    within("table", text: "Distribution") { assert_no_text "Evidence" }
    # The silent rater: a sentence, never zeroed columns.
    assert_text "No ratings yet — not counted in the org mean or any column."
    # No curation affordances on a live session
    assert_no_text "Add person from your org"

    # ── Tabs: one pane at a time, swapped in place ──
    # A sentinel that survives frame swaps but not full navigations — the
    # whole point of the pane frame is that a tab click doesn't reload (or
    # scroll) the page.
    page.execute_script("window.__staying = true")
    click_link_with_js_fallback("Capability divergence", expect_text: "CAPABILITY DIVERGENCE")
    assert_text "Strategic Thinking"
    assert_text "spread 3.0"
    assert_text "raters disagree"
    # The capability comparison spans all 4 raters' cells on it.
    assert_text "1 of 4 carried"
    # …and the silent rater is a footnote here, not a legend colour with no
    # dot behind it. One pane at a time: the strip is gone.
    assert_text "Quinn Alderberry hasn't rated yet — not on the board."
    assert_no_text "RATER TENDENCY"

    # ── Score by level ──
    # JS-dispatched so Selenium's scroll-into-view can't touch scrollY, and
    # in a SHORT viewport so the fixture page actually scrolls: the frame
    # swap must leave the room's scroll position alone — the entire reason
    # the tabs live in a pane frame.
    page.driver.browser.manage.window.resize_to(1400, 500)
    page.execute_script("window.scrollTo(0, 300)")
    assert_operator page.evaluate_script("window.scrollY"), :>=, 300,
                    "the instrument needs a page that scrolls"
    click_with_retry(expect_text: "SCORE BY LEVEL") do
      page.execute_script(<<~JS)
        [...document.querySelectorAll("a[role='tab']")]
          .find((a) => a.textContent.includes("Score by level")).click()
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
    # …and the divergence board's drill-in links carry the pins too — a
    # view switch never discards the comparison.
    click_link_with_js_fallback("Capability divergence", expect_text: "CAPABILITY DIVERGENCE")
    assert_selector "[data-drawer-card='#{nia_id}']", count: 1
    assert_selector "a[href*='capabilities'][href*='pins%5B%5D=#{nia_id}']"
    click_link_with_js_fallback("Score by level", expect_text: "SCORE BY LEVEL")

    # The drawer composes with the drill-in rather than growing a grid —
    # and the pins ride along into it.
    assert_selector "a[href*='capabilities'][href*='person=']", minimum: 1
    click_selector_with_js_fallback(
      "a[href*='capabilities'][href*='person=']",
      expect_text: "AT-LEVEL RATINGS BY LEVEL"
    )
    assert_includes page.current_url, "pins%5B%5D=#{nia_id}"
    assert_selector "[data-drawer-card='#{nia_id}']"

    # ── The cohort axis on a phone: scrolls inside its own container ──
    page.driver.browser.manage.window.resize_to(375, 812)
    visit calibration_session_path(@live_session_id, view: "cohort")
    assert_text "SCORE BY LEVEL"
    overflowing = page.evaluate_script(<<~JS)
      (() => {
        const wrap = [...document.querySelectorAll(".overflow-x-auto")]
          .find((el) => el.querySelector("a[aria-label*='% of expected']"));
        return wrap.scrollWidth > wrap.clientWidth &&
               document.documentElement.scrollWidth <= window.innerWidth + 1;
      })()
    JS
    assert overflowing, "the axis scrolls inside its wrapper, never the page body"
    # A dot is still reachable after scrolling the wrapper.
    page.execute_script(<<~JS)
      const wrap = [...document.querySelectorAll(".overflow-x-auto")]
        .find((el) => el.querySelector("a[aria-label*='% of expected']"));
      wrap.scrollLeft = wrap.scrollWidth;
      [...wrap.querySelectorAll("a[aria-label*='% of expected']")].at(-1).click();
    JS
    assert_text "rated by"
    page.driver.browser.manage.window.resize_to(1400, 1400)

    # Back to the session page for the rest of the flow — a deep link to
    # the cohort tab renders it directly (the ?view= param is shareable),
    # then over to the strip for the vocabulary check.
    visit calibration_session_path(@live_session_id, view: "cohort")
    assert_text "SCORE BY LEVEL"
    click_link_with_js_fallback("Rater tendency", expect_text: "RATER TENDENCY")

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

    # ── Drill-in: divergence row → per-level frequency axes ──
    click_link_with_js_fallback("Capability divergence", expect_text: "CAPABILITY DIVERGENCE")
    click_link_with_js_fallback("Strategic Thinking", expect_text: "AT-LEVEL RATINGS BY LEVEL")
    assert_text "AT-LEVEL RATINGS BY LEVEL"
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
    assert dot["title"].start_with?("Ivy IC — L3 · "), "the tooltip names the person and the rating"
    assert dot["aria-label"].start_with?("Ivy IC —"),
      "the accessible name carries the person, not just their initials"

    # Opening a dot shows their card.
    # The card container is already in the DOM as an empty frame, so it can't
    # be the signal — assert on content only the opened card renders.
    click_selector_with_js_fallback("a[data-person-id='#{@report_1.id}']",
                                    expect_text: "Manager: Consistently")
    assert_text "Ivy IC"
    assert_text "Manager: Consistently"

    # ── The pane swaps in place: the room keeps its scroll position ──
    # A full-page navigation would scroll back to the top, hiding the very
    # card that was just opened. Shrink the window first so the drill-in
    # actually overflows — on a tall window scrollY is 0 either way and the
    # assertion could never fail.
    # The drill-in is a single-scroll-pane layout — the PANE is the
    # scroller the swap must not move (the window never scrolls here).
    page.driver.browser.manage.window.resize_to(1000, 600)
    page.execute_script("document.getElementById('drill-in-scroll').scrollTop = 300")
    scrolled = page.evaluate_script("document.getElementById('drill-in-scroll').scrollTop")
    assert_operator scrolled, :>, 100, "precondition: the pane must be scrollable to test this"

    # JS-dispatched on purpose: a pointer click would scroll the link into
    # view first (Selenium mechanics), which is exactly the movement this
    # step exists to rule out for the SWAP itself.
    page.execute_script(<<~JS)
      [...document.querySelectorAll("a")]
        .find((a) => a.textContent.includes("Feedback / Evidence wall")).click()
    JS
    assert_text "2 items"
    assert_equal scrolled,
                 page.evaluate_script("document.getElementById('drill-in-scroll').scrollTop"),
                 "switching panes must not move the pane"
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
    # Deliberately unguarded: this re-opens a card that is already showing, so
    # there is no transition a fallback could detect. A dropped click surfaces
    # immediately on the guarded Pin click below, which needs the open card.
    find("a[data-person-id='#{@report_1.id}']").click
    click_link_with_js_fallback(
      "Pin", expect_selector: "[data-drawer-card='#{@report_1.id}'] a[aria-label^='Unpin']"
    )
    assert_selector "[data-drawer-card='#{@report_1.id}']"
    assert_text "Ran the pricing spike end to end."

    # Open the second person — the pinned card stays put beside the
    # inspector, so the room reads both at once.
    # Their name is already on the grid dot — their drawer card appearing is
    # what the click actually produces.
    click_selector_with_js_fallback("a[data-person-id='#{@report_2.id}']",
                                    expect_selector: "[data-drawer-card='#{@report_2.id}']")
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

  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE = [ 375, 812 ].freeze

  # Every level reads as its own frequency axis: the expectation beside its
  # dots, each dot in its frequency's column, the unrated off the axis.
  def assert_drill_in_axis
    within("[data-level-row='3']") do
      # Pax counts too: the level's population, whether rated or not.
      assert_text "6 people"
      assert_selector "[data-frequency='consistent'] a[data-person-id='#{@report_1.id}']"
      assert_selector "[data-frequency='none'] a[data-person-id='#{@report_2.id}']"
      # Unrated sits off the axis, in its own slot, still a link to the card.
      assert_selector "a[data-person-id='#{@uma_id}']"
      assert_no_selector "[data-frequency] a[data-person-id='#{@uma_id}']"
    end
    # The silent rater still collapses to one sentence, outside every row.
    assert_selector "p[data-silent-raters]", text: "Quinn Alderberry hasn't rated this capability yet"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1"),
           "the drill-in must not scroll the page sideways"
    overflowing = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("[data-level-row] [data-frequency]")].flatMap((column) => {
        const box = column.getBoundingClientRect()
        return [...column.querySelectorAll("a")]
          .filter((dot) => {
            const r = dot.getBoundingClientRect()
            return r.left < box.left - 1 || r.right > box.right + 1
          })
          .map((dot) => dot.dataset.personId)
      })
    JS
    assert_empty overflowing, "same-frequency dots stay inside their own column"
  end

  test "drill-in plots each level on a frequency axis at both viewports" do
    seed_live_session(with_unrated: true)
    sign_in_as(@facilitator_user)

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
    visit calibration_session_capability_path(@live_session_id, @cap_a.stable_id)
    assert_text "AT-LEVEL RATINGS BY LEVEL"
    assert_drill_in_axis
    # The divergence-board row the room clicked: each rater's mean, flagged.
    within("[data-orientation-row]") do
      assert_text "raters disagree"
      assert_selector "[data-rater-id='#{@em_1.id}'][title^='Mia Manager — mean 3.00']"
      assert_selector "[data-rater-id='#{@em_2.id}']"
    end
    # Level header beside the axis on desktop, stacked above it on a phone.
    header, axis = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector("[data-level-row='3']")
        return [row.children[0].getBoundingClientRect().top, row.children[1].getBoundingClientRect().top]
      })()
    JS
    assert_in_delta header, axis, 30, "desktop: the expectation sits beside its dots"

    page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    visit calibration_session_capability_path(@live_session_id, @cap_a.stable_id)
    assert_text "AT-LEVEL RATINGS BY LEVEL"
    assert_drill_in_axis
    header_bottom, axis_top = page.evaluate_script(<<~JS)
      (() => {
        const row = document.querySelector("[data-level-row='3']")
        return [row.children[0].getBoundingClientRect().bottom, row.children[1].getBoundingClientRect().top]
      })()
    JS
    assert_operator axis_top, :>=, header_bottom - 1, "mobile: the axis drops below its expectation"
    # A deep link to the filter renders it dimmed before any script runs.
    visit calibration_session_capability_path(@live_session_id, @cap_a.stable_id, rater: @em_2.id)
    assert_selector "button[aria-pressed='true']", text: "Raj Rater"
    assert_selector "a[data-person-id='#{@report_1.id}'][data-dimmed='true']"
    assert_no_selector "a[data-person-id='#{@report_2.id}'][data-dimmed='true']"
  ensure
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  end

  test "the drill-in legend filters to one rater and keeps it across pane swaps" do
    seed_live_session(with_unrated: true)
    sign_in_as(@facilitator_user)
    visit calibration_session_capability_path(@live_session_id, @cap_a.stable_id)
    assert_text "AT-LEVEL RATINGS BY LEVEL"
    wait_for_stimulus "drill-in-filter"
    assert_no_selector "[data-rater-id][data-dimmed='true']"

    raj_chip = "button[data-drill-in-filter-rater-param='#{@em_2.id}']"
    assert_operator page.evaluate_script(%(document.querySelector("#{raj_chip}").getBoundingClientRect().height)),
                    :>=, 44, "the chip is the filter's only control, so it takes a full tap target"
    click_selector_with_js_fallback(raj_chip, expect_selector: "#{raj_chip}[aria-pressed='true']")
    # Mia's people (and her mean) dim; Raj's stay; dimmed dots stay links.
    assert_selector "a[data-person-id='#{@report_1.id}'][data-dimmed='true']"
    assert_selector "a[data-person-id='#{@uma_id}'][data-dimmed='true']"
    assert_selector "[data-orientation-row] [data-rater-id='#{@em_1.id}'][data-dimmed='true']"
    # …and the dimming actually renders: the disc fades, its backdrop doesn't.
    disc = "a[data-person-id='#{@report_1.id}'] > span > span"
    assert_equal "0.3", page.evaluate_script(%(getComputedStyle(document.querySelector("#{disc}")).opacity))
    assert_no_selector "a[data-person-id='#{@report_2.id}'][data-dimmed='true']"
    assert_includes page.current_url, "rater=#{@em_2.id}"

    # Opening a person swaps the pane; the filter rides the new URL and the
    # grid keeps its dimming.
    click_selector_with_js_fallback("a[data-person-id='#{@report_1.id}']",
                                    expect_selector: "#calibration-person-card")
    assert_includes page.current_url, "person=#{@report_1.id}"
    assert_includes page.current_url, "rater=#{@em_2.id}"
    assert_selector "a[data-person-id='#{@report_1.id}'][data-dimmed='true']"

    # The same chip again clears it, and the URL with it.
    click_selector_with_js_fallback(raj_chip, expect_selector: "#{raj_chip}[aria-pressed='false']")
    assert_no_selector "[data-rater-id][data-dimmed='true']"
    assert_not_includes page.current_url, "rater="
    assert_includes page.current_url, "person=#{@report_1.id}"
  end

  # Readiness moves with every rated cell, and the live page keeps itself
  # current: Refresh on demand, a poll otherwise — held while the room is
  # reading a comparison card, applied the moment it closes.
  test "readiness counts cells and the live page refreshes itself" do
    live_session_with_ladder
    sign_in_as(@facilitator_user)
    visit calibration_session_path(@live_session_id)

    assert_text "Live · ratings as of"
    within("#calibration-readiness") do
      assert_text "25% rated"
      assert_text "0 of 2 people fully rated"
    end
    # Collapsed once live — the strip is the live question.
    page.execute_script("document.querySelector('details[data-readiness-raters] summary').click()")
    within("[data-readiness-rater='#{@em_1.id}']") { assert_text "1 unrated" }
    within("[data-readiness-rater='#{@em_2.id}']") { assert_text "2 unrated" }

    # A rating lands; Refresh brings it in and says what moved.
    ActsAsTenant.with_tenant(@tenant) { rate(@report_2, @cap_a, "some") }
    wait_for_stimulus "calibration-freshness"
    click_button_with_js_fallback "Refresh", expect_text: "Updated just now"
    within("#calibration-freshness-status") do
      assert_text "1 rating changed"
      assert_text "Raj Rater ×1"
      assert_text "Readiness 25% → 50%"
    end
    within("#calibration-readiness") { assert_text "50% rated" }
    # A reload keeps the rater table as the reader left it.
    assert_selector "details[data-readiness-raters][open]"
    page.execute_script("document.querySelector(\"#calibration-freshness-status button[aria-label='Dismiss update']\").click()")
    assert_no_text "Updated just now"

    # With a comparison card open, the poll holds the reload…
    visit calibration_session_path(@live_session_id, view: "cohort", person: @report_1.id)
    assert_selector "#calibration-comparison-drawer [data-drawer-card]"
    wait_for_stimulus "calibration-freshness"
    ActsAsTenant.with_tenant(@tenant) { rate(@report_2, @cap_b, "occasional") }
    page.execute_script(
      "document.querySelector('[data-controller~=\"calibration-freshness\"]')" \
      ".setAttribute('data-calibration-freshness-interval-value', '300')"
    )
    assert_text "Newer ratings are waiting"
    assert_no_text "Updated just now"
    within("#calibration-readiness") { assert_text "50% rated" }

    # …and applies it the moment the drawer collapses.
    page.execute_script("document.querySelector('[data-comparison-drawer-target=\"collapse\"]').click()")
    assert_text "Updated just now"
    within("#calibration-readiness") { assert_text "75% rated" }
    assert_no_text "Newer ratings are waiting"
  end

  test "readiness and Refresh fit a phone" do
    live_session_with_ladder
    page.driver.browser.manage.window.resize_to(375, 812)
    sign_in_as(@facilitator_user)
    visit calibration_session_path(@live_session_id)

    assert_text "Live · ratings as of"
    assert_selector "button", text: "Refresh"
    within("#calibration-readiness") { assert_text "25% rated" }
    page.execute_script("document.querySelector('details[data-readiness-raters] summary').click()")
    assert_selector "[data-readiness-rater='#{@em_1.id}']"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1"),
           "the rater table scrolls inside its card, never the page"
  ensure
    page.driver.browser.manage.window.resize_to(1400, 1400)
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
      handler.create_capability_role_binding(fw_id, SecureRandom.uuid_v7, cap_id, role_id)
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
    assert_text "AT-LEVEL RATINGS BY LEVEL"

    # The expectation sits beside its level's dots; the examples and the ⚑
    # flags live in the ⓘ menu under it.
    within("[data-level-menu='3']") { assert_text "Shapes team direction" }
    open_dropdown(scope: "[data-level-menu='3']")
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
    js_fill_in "#flag-reason-3", with: "Scope or altitude?"
    click_button_with_js_fallback "Raise clarification", expect_text: "clarification discussion is now open"

    # One flag per cell per session: the marker replaces the affordance.
    open_dropdown(scope: "[data-level-menu='3']")
    assert_text "⚑ Flagged — 1 open clarification on the framework"
    assert_no_selector "summary", text: "⚑ Flag expectation as unclear"

    # ── An EXAMPLE is flaggable on its own — narrower than the cell ──
    page.execute_script(<<~JS)
      document.querySelectorAll("details > summary").forEach((s) => {
        if (s.textContent.includes("Flag example")) s.parentElement.open = true
      })
    JS
    js_fill_in "textarea[aria-label^='Why this example is unclear']", with: "Reads as an L5 behaviour"
    click_button_with_js_fallback "Flag example", expect_text: "Example flagged"
    open_dropdown(scope: "[data-level-menu='3']")
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
    js_fill_in "#revisit-note", with: "Compare against the two peers we just discussed"
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
    js_fill_in "#evidence-request-message", with: "Nobody could answer what good looks like here"
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

    js_fill_in "#session-note", with: "Add the two reference ICs to the org-wide session"
    click_button_with_js_fallback "Record note", expect_text: "Note recorded."
    assert_text "Add the two reference ICs to the org-wide session"

    # A note recorded from the DRILL-IN stays on the drill-in and carries
    # the capability it was about — the panel exists so the room doesn't
    # get yanked out of the discussion.
    # `activity=open` wins over the cookie, so this doesn't depend on
    # whatever state the toggling above left behind.
    visit calibration_session_capability_path(@flag_session_id, @flag_cap_stable, activity: "open")
    assert_selector "#calibration-log-pane[data-pane-state='open']"
    js_fill_in "#session-note", with: "Ratings here look a level high"
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

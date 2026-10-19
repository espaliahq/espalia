# frozen_string_literal: true

require "test_helper"

class CalibrationSessionsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @facilitator_user = create(:user, password: "password123")
    @em_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @facilitator = create(:person, tenant: @tenant, email: @facilitator_user.email, name: "Dana Dept")
      @em = create(:person, tenant: @tenant, email: @em_user.email, name: "Mia Manager", manager: @facilitator)
      @report = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em)

      create(:tenant_user, tenant: @tenant, user: @facilitator_user, person: @facilitator)
      create(:tenant_user, tenant: @tenant, user: @em_user, person: @em)
      create(:tenant_user, tenant: @tenant, user: @member_user)

      @cycle = create(:assessment_cycle, tenant: @tenant, name: "H1 2026")
      create(:person_framework_assignment, tenant: @tenant,
             person_id: @report.id, framework_id: @cycle.framework_id)
    end
  end

  context "as a facilitator (manager of managers)" do
    setup { sign_in @facilitator_user }

    should "render index, new, and create a seeded draft session" do
      get calibration_sessions_path
      assert_response :success
      assert_includes response.body, "Calibration"

      get new_calibration_session_path
      assert_response :success
      assert_includes response.body, "Define calibration session"

      post calibration_sessions_path, params: {
        calibration_session: {
          name: "Engineering calibration",
          cycle_id: @cycle.cycle_id,
          participant_ids: [ @em.id ]
        }
      }
      session_record = ActsAsTenant.with_tenant(@tenant) { CalibrationSession.last }
      assert_redirected_to calibration_session_path(session_record)
      ActsAsTenant.with_tenant(@tenant) do
        assert_equal [ @em.id ], session_record.participants.pluck(:person_id)
        assert_equal [ @report.id ], session_record.calibrants.pluck(:person_id),
          "population seeds from the participant's reports"
      end
    end

    should "render the draft session page with population and readiness" do
      session_record = define_session
      get calibration_session_path(session_record)

      assert_response :success
      assert_includes response.body, "Engineering calibration"
      assert_includes response.body, "Ivy IC"
      assert_includes response.body, "Not enrolled"
    end

    should "badge an entirely-carried manager side as To confirm, not In progress" do
      session_record = define_session
      ActsAsTenant.with_tenant(@tenant) do
        role = create(:framework_role, tenant: @tenant)
        category = create(:framework_capability_category, tenant: @tenant, framework_id: @cycle.framework_id)
        cap = create(:framework_capability, tenant: @tenant, category_id: category.category_id)
        create(:framework_capability_role_binding, tenant: @tenant,
          capability_id: cap.capability_id, role_id: role.role_id)
        create(:framework_behavioural_expectation, tenant: @tenant, capability_id: cap.capability_id, level_ordinal: 2)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, person_id: @report.id,
          role_id: role.role_id, level_ordinal: 2)
        create(:assessment_level_rating,
          tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @report.id,
          framework_id: @cycle.framework_id, capability_stable_id: cap.stable_id,
          level_ordinal: 2, manager_rated_frequency: "consistent",
          manager_rating_source: "seeded", source: "seeded")
      end

      get calibration_session_path(session_record)
      assert_response :success
      assert_includes response.body, "To confirm"
      assert_not_includes response.body, "In progress"
      # The readiness card counts the carried cell as rated, and names the
      # work left — the old people-count bar read this as 0 of 1.
      assert_includes response.body, "100% rated"
      assert_includes response.body, "All 1 to confirm"
    end

    should "ignore ratings outside the assessed role in the readiness badges" do
      session_record = define_session
      ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, person_id: @report.id,
          role_id: create(:framework_role, tenant: @tenant).role_id, level_ordinal: 2)
        create_out_of_scope_rating(person_id: @report.id, cycle: @cycle, level_ordinal: 2)
      end

      get calibration_session_path(session_record)
      assert_response :success
      assert_not_includes response.body, "In progress"
      assert_not_includes response.body, "To confirm"
    end
  end

  context "participant candidates (picker typeahead)" do
    setup do
      ActsAsTenant.with_tenant(@tenant) do
        other_head = create(:person, tenant: @tenant, name: "Kim Elsewhere")
        @other_em = create(:person, tenant: @tenant, name: "Miriam Otherteam", manager: other_head)
        create(:person, tenant: @tenant, name: "Ref IC", manager: @other_em)
      end
    end

    should "scope a manager's search to their own subtree" do
      sign_in @facilitator_user
      get participant_candidates_calibration_sessions_path(q: "mi")

      assert_response :success
      assert_includes response.body, "Mia Manager"
      assert_not_includes response.body, "Miriam Otherteam"
    end

    should "deny a member without reports" do
      sign_in @member_user
      get participant_candidates_calibration_sessions_path(q: "mi")

      assert_redirected_to root_path
    end
  end

  context "adding participants from the picker" do
    should "add every selected person in one POST" do
      session_record = define_session
      new_em = ActsAsTenant.with_tenant(@tenant) do
        em = create(:person, tenant: @tenant, name: "Noor Newlead", manager: @facilitator)
        create(:person, tenant: @tenant, name: "Nate IC", manager: em)
        em
      end

      sign_in @facilitator_user
      post calibration_session_participants_path(session_record),
           params: { person_ids: [ new_em.id ] }

      assert_redirected_to calibration_session_path(session_record)
      ActsAsTenant.with_tenant(@tenant) do
        assert_includes session_record.participants.pluck(:person_id), new_em.id
      end
    end
  end

  context "a rater with nothing rated on a live session" do
    setup do
      sign_in @facilitator_user
      ActsAsTenant.with_tenant(@tenant) do
        # Quinn brings a report but no ratings; Mia rates hers, so the strip
        # is a live table with one silent row rather than the empty state.
        @quinn = create(:person, tenant: @tenant, name: "Quinn Alderberry", manager: @facilitator)
        quinn_report = create(:person, tenant: @tenant, name: "Pax Thistledown", manager: @quinn)
        create(:person_framework_assignment, tenant: @tenant,
               person_id: quinn_report.id, framework_id: @cycle.framework_id)
        role = create(:framework_role, tenant: @tenant)
        [ @report, quinn_report ].each do |person|
          create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
                 person_id: person.id, level_ordinal: 3, role_id: role.role_id)
        end
        category = create(:framework_capability_category, tenant: @tenant,
                          framework_id: @cycle.framework_id, name: "Thinking")
        cap = create(:framework_capability, tenant: @tenant,
                     category_id: category.category_id, name: "Strategic Thinking")
        create(:framework_capability_role_binding, tenant: @tenant,
               capability_id: cap.capability_id, role_id: role.role_id)
        create(:framework_behavioural_expectation, tenant: @tenant,
               capability_id: cap.capability_id, level_ordinal: 3)
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
               person_id: @report.id, framework_id: @cycle.framework_id,
               capability_stable_id: cap.stable_id, level_ordinal: 3,
               manager_rated_frequency: "consistent")

        # A second RATED rater so the board actually renders rows — with one
        # rater everything is "not comparable" and the legend never exists.
        raj = create(:person, tenant: @tenant, name: "Raj Elderbrook", manager: @facilitator)
        raj_report = create(:person, tenant: @tenant, name: "Omar IC", manager: raj)
        create(:person_framework_assignment, tenant: @tenant,
               person_id: raj_report.id, framework_id: @cycle.framework_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: raj_report.id, level_ordinal: 3, role_id: role.role_id)
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
               person_id: raj_report.id, framework_id: @cycle.framework_id,
               capability_stable_id: cap.stable_id, level_ordinal: 3,
               manager_rated_frequency: "none")

        @session_record = define_session(
          participant_ids: [ @em.id, raj.id, @quinn.id ],
          calibrant_person_ids: [ @report.id, raj_report.id, quinn_report.id ]
        )
        @session_record.update!(status: "started")
      end
    end

    # The overview is tabbed now, so each surface asserts on its own tab.
    should "say so on the strip (the default tab)" do
      get calibration_session_path(@session_record)

      assert_response :success
      # The row stays (readiness is its job) but reads as a state, not as
      # zeroed measurements.
      assert_includes response.body, "No ratings yet"
      assert_select "td[colspan='5']", text: /No ratings yet/
      # The other tabs' content is NOT on this page — one pane at a time.
      assert_not_includes response.body, "Capability divergence</h2>"
    end

    should "keep them off the board tab's legend" do
      get calibration_session_path(@session_record, view: "divergence")

      assert_response :success
      assert_includes response.body, "Quinn Alderberry hasn&#39;t rated yet — not on the board."
      # Exactly two legend swatches — the rated raters. A third would be a
      # colour promising a dot that exists on no axis.
      assert_select ".h-3.w-3.rounded-full", count: 2
    end
  end

  context "the Score by cohort tab" do
    setup do
      sign_in @facilitator_user
      ActsAsTenant.with_tenant(@tenant) do
        # A scorable fixture: level ladder + binding, one L3 cohort of two
        # people under Mia, one rated to 100%, one left gated.
        family = create(:framework_role_family, tenant: @tenant, framework_id: @cycle.framework_id)
        engineer = create(:framework_role, tenant: @tenant, role_family_id: family.role_family_id)
        (1..4).each do |ordinal|
          create(:framework_level, tenant: @tenant, role_id: engineer.role_id, ordinal: ordinal)
        end
        @category = create(:framework_capability_category, tenant: @tenant,
                           framework_id: @cycle.framework_id)
        @engineer = engineer
        @cohort_cap = create(:framework_capability, tenant: @tenant,
                             category_id: @category.category_id, name: "Strategic Thinking")
        create(:framework_capability_role_binding, tenant: @tenant,
               capability_id: @cohort_cap.capability_id, role_id: engineer.role_id)
        create(:framework_behavioural_expectation, tenant: @tenant,
               capability_id: @cohort_cap.capability_id, level_ordinal: 3)

        @gated = create(:person, tenant: @tenant, name: "Pax Thistledown", manager: @em)
        # In the facilitator's org (a lead who isn't in the room), so the
        # rating is real — but no PARTICIPANT is attributed, and the dot
        # must wear the neutral fill, not rater #1's colour.
        other_lead = create(:person, tenant: @tenant, name: "Lior Lead", manager: @facilitator)
        @outsider = create(:person, tenant: @tenant, name: "Zed Outerling", manager: other_lead)
        # @report's assignment exists from the file setup (DeterministicId
        # PK — re-creating collides); it just needs the scorable role.
        PersonFrameworkAssignment
          .find_by(person_id: @report.id, framework_id: @cycle.framework_id)
          .update!(role_id: engineer.role_id)
        [ @gated, @outsider ].each do |person|
          create(:person_framework_assignment, tenant: @tenant,
                 person_id: person.id, framework_id: @cycle.framework_id, role_id: engineer.role_id)
        end
        [ @report, @gated, @outsider ].each do |person|
          create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
                 person_id: person.id, level_ordinal: 3, role_id: engineer.role_id)
        end
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
               person_id: @report.id, framework_id: @cycle.framework_id,
               capability_stable_id: @cohort_cap.stable_id, level_ordinal: 3,
               manager_rated_frequency: "consistent", manager_rating_source: "seeded")
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
               person_id: @outsider.id, framework_id: @cycle.framework_id,
               capability_stable_id: @cohort_cap.stable_id, level_ordinal: 3,
               manager_rated_frequency: "consistent")

        @session_record = define_session(
          calibrant_person_ids: [ @report.id, @gated.id, @outsider.id ]
        )
        @session_record.update!(status: "started")
      end
    end

    should "plot scored dots, gate the unrated, and mark the tab active" do
      get calibration_session_path(@session_record, view: "cohort")

      assert_response :success
      # Tabs + content live inside the pane frame, so a tab or dot click
      # swaps in place instead of scrolling the room back to the top.
      assert_select "turbo-frame#calibration-overview-pane a[role='tab']", count: 3
      assert_select "a[role='tab'][aria-selected='true']", text: "Score by cohort"
      # Ivy: 100%, entirely carried → dashed disclosure on the dot.
      assert_select "a[aria-label*='Ivy IC — 100% of expected']"
      assert_includes response.body, "1 of 1 ratings carried forward"
      # Pax: no DOT (the gate chip's own link is fine — it opens the
      # drawer, it just must not plot a score).
      assert_select "a[aria-label*='% of expected'][aria-label*='Pax Thistledown']", count: 0
      assert_includes response.body, "0 of 1 rated"
      assert_includes response.body, "score unlocks at 1"
      # One pane at a time — the strip isn't here.
      assert_not_includes response.body, "Rater tendency</h2>"
    end

    should "give an unattributed dot the neutral fill, never a rater's colour" do
      get calibration_session_path(@session_record, view: "cohort")

      assert_response :success
      # Zed is rated to 100% by someone outside the room: plotted, honest.
      assert_select "a[aria-label*='Zed Outerling — 100% of expected, rated by someone outside this session']"
      # …and the disc is the neutral grey, never rater #1's colour.
      assert_select "a[aria-label*='Zed Outerling'] span.bg-gray-500"
      assert_includes response.body, "rated outside this session",
                      "the legend names the neutral swatch"
    end

    should "open a dot in the comparison drawer, with the rater-context line" do
      ActsAsTenant.with_tenant(@tenant) do
        # A second behaviour rated "some" so the panel has a genuine
        # pulling-down row to drill into.
        weak = create(:framework_capability, tenant: @tenant,
                      category_id: @category.category_id, name: "Delivery")
        create(:framework_capability_role_binding, tenant: @tenant,
               capability_id: weak.capability_id, role_id: @engineer.role_id)
        create(:framework_behavioural_expectation, tenant: @tenant,
               capability_id: weak.capability_id, level_ordinal: 3)
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
               person_id: @report.id, framework_id: @cycle.framework_id,
               capability_stable_id: weak.stable_id, level_ordinal: 3,
               manager_rated_frequency: "some")
      end

      get calibration_session_path(@session_record, view: "cohort", person: @report.id)

      assert_response :success
      assert_select "#calibration-comparison-drawer [data-drawer-card='#{@report.id}']"
      # The inspected person's dot reads by size — 1.5× the others.
      assert_select "a[aria-label*='Currently open in the comparison'] span.h-\\[42px\\]"
      assert_match(/\d+% of expected/, response.body)
      assert_includes response.body, "rated by Mia Manager"
      assert_includes response.body, "vs org mean"
      assert_includes response.body, "may be tendency, not Ivy IC"
      assert_select "a[href*='capabilities'][href*='#calibration-person-card']",
                    text: /Open drill-in/
      assert_includes response.body, "Delivery", "the some-rated behaviour is the weakest row"
      # Ivy's other behaviour merely meets (+0.0) — that is not "pulling
      # it up", so the strongest column stays honest and empty.
      assert_includes response.body, "Nothing above expectations yet."
    end

    should "hold a pinned person beside the inspected one, across tabs" do
      get calibration_session_path(@session_record, view: "cohort",
                                   person: @gated.id, pins: [ @report.id ])

      assert_response :success
      # Both cards, side by side: the gated inspector wears the gate's
      # copy (never a fake number), the pinned card keeps its score.
      assert_select "[data-drawer-card='#{@gated.id}']"
      assert_select "[data-drawer-card='#{@report.id}']"
      # A pinned person's dot reads by size, same as the inspected one.
      assert_select "a[aria-label*='Pinned to the comparison'] span.h-\\[42px\\]"
      assert_includes response.body, "score unlocks at"
      assert_includes response.body, "1 pinned"
      # The tab links carry the drawer, so switching views keeps it.
      assert_select "a[role='tab'][href*='pins%5B%5D=#{@report.id}']", count: 3

      get calibration_session_path(@session_record, view: "tendency", pins: [ @report.id ])
      assert_response :success
      assert_select "[data-drawer-card='#{@report.id}']",
                    { count: 1 }, "pins persist on the other tabs"
    end

    should "keep the inspector on a pinned card's links — unpin never hijacks" do
      get calibration_session_path(@session_record, view: "cohort",
                                   person: @gated.id, pins: [ @report.id ])

      assert_response :success
      # Ivy's Unpin drops HER pin but keeps Pax inspected; her drill-in
      # rows open HER card there — two different people by design.
      assert_select "[data-drawer-card='#{@report.id}'] a[aria-label^='Unpin'][href*='person=#{@gated.id}']"
      assert_select "[data-drawer-card='#{@report.id}'] a[aria-label^='Unpin'][href*='pins']", count: 0
    end

    should "carry the drawer onto the divergence board's drill-in links" do
      # A board row needs two raters on the same capability.
      session = ActsAsTenant.with_tenant(@tenant) do
        em2 = create(:person, tenant: @tenant, name: "Noor Newlead", manager: @facilitator)
        r2 = create(:person, tenant: @tenant, name: "Remy IC", manager: em2)
        create(:person_framework_assignment, tenant: @tenant,
               person_id: r2.id, framework_id: @cycle.framework_id, role_id: @engineer.role_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: r2.id, level_ordinal: 3, role_id: @engineer.role_id)
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
               person_id: r2.id, framework_id: @cycle.framework_id,
               capability_stable_id: @cohort_cap.stable_id, level_ordinal: 3,
               manager_rated_frequency: "some")
        record = define_session(participant_ids: [ @em.id, em2.id ],
                                calibrant_person_ids: [ @report.id, r2.id ])
        record.update!(status: "started")
        record
      end

      get calibration_session_path(session, view: "divergence",
                                   person: @report.id, pins: [ @report.id ])

      assert_response :success
      # The capability rows are the way into the drill-in — a view switch
      # must never discard the comparison.
      assert_select "a[href*='capabilities'][href*='person=#{@report.id}'][href*='pins%5B%5D=#{@report.id}']"
    end

    should "render no drawer card for a foreign person" do
      get calibration_session_path(@session_record, view: "cohort",
                                   person: SecureRandom.uuid_v7)
      assert_response :success
      assert_select "#calibration-comparison-drawer", count: 0
    end

    should "fall back to the tendency tab on a mangled view param" do
      get calibration_session_path(@session_record, view: "garbage")

      assert_response :success
      assert_select "a[role='tab'][aria-selected='true']", text: "Rater tendency"
    end
  end

  context "lifecycle endpoints as facilitator" do
    should "start then close the session" do
      session_record = define_session
      sign_in @facilitator_user

      post start_calibration_session_path(session_record)
      assert_redirected_to calibration_session_path(session_record)
      assert_equal "started", session_record.reload.status

      post close_calibration_session_path(session_record)
      assert_redirected_to calibration_session_path(session_record)
      session_record.reload
      assert_equal "closed", session_record.status
      assert_equal "facilitator", session_record.close_reason
    end
  end

  context "as a participant EM (v1 facilitator-only)" do
    should "deny the session page" do
      session_record = define_session
      sign_in @em_user

      get calibration_session_path(session_record)
      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  context "as a member without reports" do
    should "redirect from index" do
      sign_in @member_user
      get calibration_sessions_path

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  private

  def define_session(participant_ids: nil, calibrant_person_ids: nil)
    ActsAsTenant.with_tenant(@tenant) do
      result = Operations::CalibrationSessions::Define.call(
        context: AuthorizationContext.new(
          user: @facilitator_user,
          tenant_user: TenantUser.find_by(user: @facilitator_user),
          person: @facilitator
        ),
        params: {
          cycle_id: @cycle.cycle_id, name: "Engineering calibration",
          participant_ids: participant_ids || [ @em.id ],
          calibrant_person_ids: calibrant_person_ids || [ @report.id ]
        }
      )
      CalibrationSession.find(result[:session_id])
    end
  end
end

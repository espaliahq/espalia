# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::CapabilitiesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @facilitator_user = create(:user, password: "password123")
    @em_user = create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @facilitator = create(:person, tenant: @tenant, email: @facilitator_user.email, name: "Dana Dept")
      @em = create(:person, tenant: @tenant, email: @em_user.email, name: "Mia Manager", manager: @facilitator)
      @report = create(:person, tenant: @tenant, name: "Ivy IC", manager: @em)
      create(:tenant_user, tenant: @tenant, user: @facilitator_user, person: @facilitator)
      create(:tenant_user, tenant: @tenant, user: @em_user, person: @em)

      # Real streams throughout, not factory read-model rows: an outcome POST
      # against a stream-less session fails in the aggregate and answers from
      # the rescue branch, where the redirect looks identical — so the
      # success path would never actually be under test. The flag also raises
      # a framework clarification, which needs a real framework stream.
      framework_id, role_id, level_id = seed_framework

      # The PD assignment goes in before the cycle row exists, so
      # AutoEnrollNewAssignments doesn't reach for a factory cycle that has
      # no event stream. Its projection writes the assignment row too.
      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
        PersonDevelopment::CommandHandler.new.assign_to_framework(
          @report.id, framework_id, role_id, level_id
        )
      end
      @cycle = create(:assessment_cycle, tenant: @tenant, framework_id: framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: @report.id, level_ordinal: 3, role_id: role_id)

      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
             person_id: @report.id, framework_id: @cycle.framework_id,
             capability_stable_id: @cap.stable_id, level_ordinal: 3,
             manager_rated_frequency: "consistent", self_rated_frequency: "some")
      create(:evidence_item, tenant: @tenant, person_id: @report.id,
             framework_id: @cycle.framework_id, author_id: @em.id,
             capability_stable_id: @cap.stable_id, level_ordinal: 3,
             content: "Led the pricing re-architecture across squads.")

      @session = create(:calibration_session, tenant: @tenant,
                        cycle_id: @cycle.cycle_id, framework_id: @cycle.framework_id,
                        facilitator_id: @facilitator.id, status: "started")
      create(:calibration_session_member, :participant, tenant: @tenant,
             session: @session, person_id: @em.id)
      create(:calibration_session_member, tenant: @tenant,
             session: @session, person_id: @report.id)
    end
  end

  context "as the facilitator" do
    setup { sign_in @facilitator_user }

    should "render the drill-in grid with expectation text" do
      get calibration_session_capability_path(@session, @cap.stable_id)

      assert_response :success
      assert_includes response.body, "Strategic Thinking"
      assert_includes response.body, "Identifies root causes."
      assert_includes response.body, "Mia Manager"
    end

    should "render the person card with ratings and evidence when a dot is opened" do
      get calibration_session_capability_path(@session, @cap.stable_id, person: @report.id)

      assert_response :success
      assert_includes response.body, "Ivy IC"
      assert_includes response.body, "Manager: Consistently"
      assert_includes response.body, "Self: Some of the time"
      assert_includes response.body, "Led the pricing re-architecture"
    end

    should "mark a carried rating on the grid dot and the person card pill" do
      AssessmentLevelRating
        .find_by(cycle_id: @cycle.cycle_id, person_id: @report.id)
        .update!(manager_rating_source: "seeded")

      get calibration_session_capability_path(@session, @cap.stable_id, person: @report.id)

      assert_response :success
      # Scoped to the DOT: the legend renders an unconditional dashed
      # swatch, so a bare /border-dashed/ match would pass even with the
      # marker gone.
      assert_select "a[data-person-id=?] span.border-dashed", @report.id
      # …and stated, not left to decoration alone.
      assert_includes response.body, "carried forward from the previous cycle"
      assert_includes response.body, "· carried"
    end

    should "redirect for an unknown capability" do
      get calibration_session_capability_path(@session, SecureRandom.uuid_v7)
      assert_redirected_to calibration_session_path(@session)
    end

    should "render the evidence wall with named items and filters" do
      get calibration_session_capability_path(@session, @cap.stable_id, view: "wall")

      assert_response :success
      assert_wall_total 1
      # Who it is about and what was written, both in the open.
      assert_includes response.body, "Ivy IC"
      assert_includes response.body, "Led the pricing re-architecture"
      assert_includes response.body, "wall-filter-wall_level"
    end

    should "apply wall filters and carry them into every pane link" do
      get calibration_session_capability_path(@session, @cap.stable_id,
                                              view: "wall", wall_level: 4)

      assert_response :success
      assert_wall_total 0
      assert_not_includes response.body, "Led the pricing re-architecture"
      # Stepping out to another pane and back must return to the same filter.
      assert_includes response.body, "wall_level=4"
    end

    should "route the rater filter through to the wall" do
      # A second rater whose report also has evidence here, so a filter that
      # does nothing is distinguishable from one that works.
      other_em, = seed_second_rater

      get calibration_session_capability_path(@session, @cap.stable_id,
                                              view: "wall", wall_rater: @em.id)
      assert_wall_total 1
      assert_includes response.body, "Led the pricing re-architecture"
      assert_not_includes response.body, "Ran the billing spike"

      get calibration_session_capability_path(@session, @cap.stable_id,
                                              view: "wall", wall_rater: other_em.id)
      assert_wall_total 1
      assert_includes response.body, "Ran the billing spike"

      stranger = ActsAsTenant.with_tenant(@tenant) { create(:person, tenant: @tenant) }
      get calibration_session_capability_path(@session, @cap.stable_id,
                                              view: "wall", wall_rater: stranger.id)
      # Not a participant — the filter is rejected rather than emptying the wall.
      assert_wall_total 2
    end

    should "survive array and non-numeric filter params without erroring" do
      get calibration_session_capability_path(@session, @cap.stable_id,
                                              view: "wall", wall_level: [ "3" ])
      assert_response :success

      get calibration_session_capability_path(@session, @cap.stable_id,
                                              view: "wall", wall_level: "abc")
      assert_response :success
      # A junk level must be IGNORED, not coerced to 0 (which would empty
      # the wall while still returning 200).
      assert_wall_total 1
    end

    # The population can legitimately include someone outside the
    # facilitator's subtree: ScopeChecks exempts anyone a PARTICIPANT is
    # attributed via an active rating delegation. That person's own
    # contributions — peer feedback about them, and their self-rating — are
    # still not the facilitator's to read: /assessments would refuse them,
    # and the session must not be a way around that.
    should "withhold the assessee's own inputs outside the facilitator's entitlement" do
      outsider = ActsAsTenant.with_tenant(@tenant) do
        stranger_head = create(:person, tenant: @tenant, name: "Other Dept Head")
        seconded = create(:person, tenant: @tenant, name: "Zed Outside", manager: stranger_head)
        create(:person_framework_assignment, tenant: @tenant,
               person_id: seconded.id, framework_id: @cycle.framework_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: seconded.id, level_ordinal: 3)
        create(:manager_assessment_delegation, tenant: @tenant,
               person_id: seconded.id, framework_id: @cycle.framework_id,
               delegate_person_id: @em.id, granted_by_id: stranger_head.id)
        create(:evidence_item, tenant: @tenant, person_id: seconded.id,
               framework_id: @cycle.framework_id, author_id: stranger_head.id,
               capability_stable_id: @cap.stable_id, level_ordinal: 3,
               content: "CONFIDENTIAL peer feedback about Zed.")
        # Manager rated Some, Zed rated himself Consistently — so a leak of
        # the self value is distinguishable from the manager value.
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
               person_id: seconded.id, framework_id: @cycle.framework_id,
               capability_stable_id: @cap.stable_id, level_ordinal: 3,
               manager_rated_frequency: "some", self_rated_frequency: "consistent")
        create(:calibration_session_member, tenant: @tenant,
               session: @session, person_id: seconded.id)
        seconded
      end

      get calibration_session_capability_path(@session, @cap.stable_id, view: "wall")

      assert_response :success
      assert_not_includes response.body, "CONFIDENTIAL peer feedback",
        "the wall must not render evidence the facilitator can't read on /assessments"
      # Their own report's evidence still shows — this narrows, not disables.
      assert_includes response.body, "Led the pricing re-architecture"

      get calibration_session_capability_path(@session, @cap.stable_id, person: outsider.id)
      assert_response :success
      assert_not_includes response.body, "CONFIDENTIAL peer feedback",
        "the person card must withhold it too"
      # The self-rating is the assessee's own input and goes with it — said
      # so, not left as a blank that reads as "never rated".
      assert_includes response.body, "Self: not shown"
      assert_not_includes response.body, "Self: Consistently"
      # The MANAGER rating stays: it belongs to a rater in the room, and
      # calibrating them is why the exemption puts Zed on the grid at all.
      assert_includes response.body, "Manager: Some of the time"

      # Same rule on a PINNED drawer card, which renders the same panel.
      get calibration_session_capability_path(@session, @cap.stable_id,
                                              pins: [ outsider.id ])
      assert_response :success
      assert_includes response.body, "Self: not shown"
      assert_includes response.body, "Manager: Some of the time"
    end

    should "collapse a rater with nothing rated here into one sentence" do
      # Quinn's report is on the grid's population but Quinn hasn't rated
      # this capability — a full row of grey dots reads as data on a
      # projector, so it collapses to a sentence naming both of them.
      ActsAsTenant.with_tenant(@tenant) do
        quinn = create(:person, tenant: @tenant, name: "Quinn Alderberry", manager: @facilitator)
        pax = create(:person, tenant: @tenant, name: "Pax Thistledown", manager: quinn)
        create(:person_framework_assignment, tenant: @tenant,
               person_id: pax.id, framework_id: @cycle.framework_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: pax.id, level_ordinal: 3)
        create(:calibration_session_member, :participant, tenant: @tenant,
               session: @session, person_id: quinn.id)
        create(:calibration_session_member, tenant: @tenant,
               session: @session, person_id: pax.id)
      end

      get calibration_session_capability_path(@session, @cap.stable_id)

      assert_response :success
      assert_includes response.body, "Quinn Alderberry hasn&#39;t rated this capability yet ("
      # Pax appears as a LINK in the sentence, never as a grey dot: the
      # person card (evidence, the revisit ask) stays one click away — the
      # unrated cell is the "what did you see?" moment.
      assert_select "td[colspan] a[data-person-id]", text: "Pax Thistledown", count: 1
      assert_select "a[data-person-id] span.h-7", { count: 1 },
                    "exactly one dot row remains — the rated rater's"
      assert_select "a[data-person-id='#{@report.id}']"
    end

    should "show the self-rating for a calibrant the facilitator does manage" do
      get calibration_session_capability_path(@session, @cap.stable_id, person: @report.id)

      assert_response :success
      assert_includes response.body, "Self: Some of the time"
      assert_not_includes response.body, "Self: not shown"
    end

    should "render the drawer for pinned people, dropping foreign pins" do
      get calibration_session_capability_path(
        @session, @cap.stable_id,
        pins: [ @report.id, SecureRandom.uuid_v7, @em.id ]
      )

      assert_response :success
      assert_includes response.body, "1 pinned"
      assert_select "[data-drawer-card='#{@report.id}']"
      assert_includes response.body, "Unpin"
    end

    should "resolve pins before capping so stale ids can't squeeze out a live one" do
      stale = Array.new(CalibrationSessions::CapabilitiesController::MAX_COMPARE_PINS) { SecureRandom.uuid_v7 }

      get calibration_session_capability_path(
        @session, @cap.stable_id, pins: stale + [ @report.id ]
      )

      assert_includes response.body, "1 pinned"
      assert_select "[data-drawer-card='#{@report.id}']"
    end

    should "carry the pane, the opened person, the pins and the filters through an outcome POST" do
      start_session_stream

      post calibration_session_rating_revisits_path(@session), params: {
        person_id: @report.id, capability_stable_id: @cap.stable_id,
        level_ordinal: 3, note: "Compare the pricing work with Omar's.",
        pins: [ @report.id ], view: "wall", wall_valence: "demonstrated"
      }

      assert_equal "Revisit requested — it will appear in the rater's assessment activity.",
                   flash[:notice], "the success path, not the rescue branch"
      assert_includes response.redirect_url, "pins%5B%5D=#{@report.id}"
      assert_includes response.redirect_url, "person=#{@report.id}"
      assert_includes response.redirect_url, "view=wall"
      assert_includes response.redirect_url, "wall_valence=demonstrated"
      assert_includes response.redirect_url, "activity=open",
        "the ask must land somewhere visible even with the log panel closed"
    end

    should "render the whole ladder read-only, focused at the assessed level" do
      # Rated ABOVE their level — the reason the card shows every level.
      ActsAsTenant.with_tenant(@tenant) do
        create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
               person_id: @report.id, framework_id: @cycle.framework_id,
               capability_stable_id: @cap.stable_id, level_ordinal: 4,
               manager_rated_frequency: "occasional")
        create(:evidence_item, tenant: @tenant, person_id: @report.id,
               framework_id: @cycle.framework_id, author_id: @em.id,
               capability_stable_id: @cap.stable_id, level_ordinal: 4,
               content: "Already operating at staff scope on the platform bet.")
      end

      get calibration_session_capability_path(@session, @cap.stable_id, person: @report.id)

      assert_response :success
      # One chip per ladder level; focus (aria-current) sits at the
      # assessed level by default, which also wears the CURRENT badge.
      assert_select "a[aria-current='true'][href*='person_level=3']"
      assert_select "a[href*='person_level=4']"
      assert_includes response.body, "CURRENT"
      assert_includes response.body, "Identifies root causes."
      assert_includes response.body, "Feedback / Evidence at L3"

      get calibration_session_capability_path(@session, @cap.stable_id,
                                              person: @report.id, person_level: 4)

      assert_response :success
      # The focused panel is now the above-level cell: its expectation,
      # its rating, its evidence.
      assert_select "a[aria-current='true'][href*='person_level=4']"
      assert_includes response.body, "Shapes system direction."
      # Scoped to the card — the frequency legend renders the same phrase
      # elsewhere on the page.
      assert_select "#calibration-person-card span", text: /Manager: Most of the time/
      assert_includes response.body, "Already operating at staff scope on the platform bet."
      assert_not_includes response.body, "Led the pricing re-architecture across squads.",
                          "the L3 evidence belongs to the L3 panel"
    end

    should "scope the kebab's asks to the focused level" do
      get calibration_session_capability_path(@session, @cap.stable_id,
                                              person: @report.id, person_level: 4,
                                              person_action: "revisit")

      assert_response :success
      assert_includes response.body, "to revisit this rating at L4"
      assert_select "form[action*='rating_revisits'] input[name='level_ordinal'][value='4']"

      get calibration_session_capability_path(@session, @cap.stable_id,
                                              person: @report.id, person_level: 4,
                                              person_action: "request")
      assert_select "form[action*='evidence_requests'] input[name='level_ordinal'][value='4']"
    end

    should "not leak the focused level onto links that open a different person" do
      _other_em, other_report = seed_second_rater

      get calibration_session_capability_path(@session, @cap.stable_id,
                                              person: @report.id, person_level: 4)

      assert_response :success
      # Omar's dot must open HIS card at HIS assessed level — Ivy's focused
      # ordinal belongs to Ivy's open card only.
      assert_select "a[data-person-id='#{other_report.id}'][href*='person_level']", count: 0
      assert_select "a[data-person-id='#{other_report.id}']"
    end

    should "fall back to the assessed level on a mangled person_level" do
      get calibration_session_capability_path(@session, @cap.stable_id,
                                              person: @report.id, person_level: 99)

      assert_response :success
      assert_select "a[aria-current='true'][href*='person_level=3']"
    end

    should "carry the same state through a flag POST, which names the person differently" do
      start_session_stream

      post calibration_session_expectation_flags_path(@session), params: {
        capability_stable_id: @cap.stable_id, level_ordinal: 3,
        reason: "Scope or altitude?", person: @report.id,
        pins: [ @report.id ], view: "wall"
      }

      assert_match(/clarification discussion is now open/, flash[:notice].to_s,
                   "the success path, not the rescue branch")
      assert_includes response.redirect_url, "person=#{@report.id}"
      assert_includes response.redirect_url, "pins%5B%5D=#{@report.id}"
      assert_includes response.redirect_url, "view=wall"
      assert_includes response.redirect_url, "activity=open"
    end

    should "offer the request affordance, fire it, and land it in the log" do
      start_session_stream

      get calibration_session_capability_path(@session, @cap.stable_id, person: @report.id)
      assert_response :success
      # The affordance lives in the card's kebab; the form opens on demand.
      assert_select "a[href*='person_action=request']", text: /Request feedback \/ evidence/
      assert_select "select[name='requestee_person_id']", count: 0

      get calibration_session_capability_path(@session, @cap.stable_id,
                                              person: @report.id, person_action: "request")
      assert_response :success
      assert_includes response.body, "Request feedback / evidence about Ivy IC"
      # Mia (the manager) is an org neighbour; the facilitator isn't listed.
      assert_select "select[name='requestee_person_id'] option", text: /Mia Manager/

      post calibration_session_evidence_requests_path(@session), params: {
        person_id: @report.id, requestee_person_id: @em.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 3,
        message: "The room couldn't answer what good looks like here."
      }
      assert_match(/requested — it lands on their hub/, flash[:notice].to_s,
                   "the success path, not the rescue branch")
      assert_includes response.redirect_url, "activity=open"

      request = EvidenceRequest.sole
      assert_equal @em.id, request.requestee_person_id

      # The log entry, with fulfilment read from the request itself.
      get calibration_session_capability_path(@session, @cap.stable_id)
      assert_includes response.body, "Asked Mia Manager for feedback / evidence"
      assert_includes response.body, "Awaiting response"

      # …and the pending ask greys Mia out of a second offer.
      get calibration_session_capability_path(@session, @cap.stable_id,
                                              person: @report.id, person_action: "request")
      assert_select "select[name='requestee_person_id'] option[disabled]", text: /already asked/

      # Fulfilment is live: the read model says "responded", the room reads
      # a green "Answered" — the key must match EvidenceRequest::STATUSES
      # verbatim or the label silently falls back to a gray humanize.
      request.update!(status: "responded")
      get calibration_session_capability_path(@session, @cap.stable_id)
      assert_select "span.text-green-700", text: "Answered"
      assert_not_includes response.body, "Awaiting response"
    end

    should "not offer the request affordance outside the assessment entitlement" do
      outsider = ActsAsTenant.with_tenant(@tenant) do
        stranger_head = create(:person, tenant: @tenant, name: "Other Dept Head")
        seconded = create(:person, tenant: @tenant, name: "Zed Outside", manager: stranger_head)
        create(:person_framework_assignment, tenant: @tenant,
               person_id: seconded.id, framework_id: @cycle.framework_id)
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
               person_id: seconded.id, level_ordinal: 3)
        create(:manager_assessment_delegation, tenant: @tenant,
               person_id: seconded.id, framework_id: @cycle.framework_id,
               delegate_person_id: @em.id, granted_by_id: stranger_head.id)
        create(:calibration_session_member, tenant: @tenant,
               session: @session, person_id: seconded.id)
        seconded
      end

      get calibration_session_capability_path(@session, @cap.stable_id, person: outsider.id)
      assert_response :success
      assert_not_includes response.body, "Request feedback / evidence about Zed Outside",
                          "no affordance for a person whose assessment the facilitator can't read"

      # …and the POST is refused by the Operation even if forged.
      post calibration_session_evidence_requests_path(@session), params: {
        person_id: outsider.id, requestee_person_id: @em.id,
        capability_stable_id: @cap.stable_id, level_ordinal: 3
      }
      assert_response :redirect
      assert flash[:alert].present?
      assert_equal 0, EvidenceRequest.count
    end

    should "leave the log panel closed when an outcome POST fails" do
      start_session_stream

      post calibration_session_expectation_flags_path(@session), params: {
        capability_stable_id: @cap.stable_id, level_ordinal: 99,
        reason: "No such level.", person: @report.id
      }

      assert flash[:alert].present?
      assert_not_includes response.redirect_url, "activity=open",
        "nothing was recorded, so there is nothing to open the panel for"
    end

    should "not error when an outcome POST carries a hash pins param" do
      start_session_stream

      post calibration_session_rating_revisits_path(@session), params: {
        person_id: @report.id, capability_stable_id: @cap.stable_id,
        level_ordinal: 3, note: "Malformed state.", pins: { "x" => "y" }
      }

      assert_response :redirect
      assert_not_includes response.redirect_url, "pins"
    end
  end

  context "as a participant EM (v1 facilitator-only)" do
    should "deny the drill-in" do
      sign_in @em_user
      get calibration_session_capability_path(@session, @cap.stable_id)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
    end
  end

  # The wall's count, read from `data-wall-total` rather than the visible
  # text: "1 item" is a substring of the utility class `min-h-11
  # items-center`, so a body-substring assertion on it passes even on a
  # page that renders no wall at all.
  def assert_wall_total(expected)
    assert_select %(p[data-wall-total="#{expected}"]), { count: 1 },
      "expected the wall to report #{expected} item(s)"
  end

  # One published framework on a real stream, with the names the assertions
  # read back. Sets @cap to the projected capability so tests keep using
  # `@cap.stable_id` / `@cap.capability_id`.
  #
  # @return [Array(String, String, String)] framework_id, role_id, level_id
  def seed_framework
    framework_id = SecureRandom.uuid_v7
    family_id = SecureRandom.uuid_v7
    role_id = SecureRandom.uuid_v7
    level_id = SecureRandom.uuid_v7
    category_id = SecureRandom.uuid_v7
    capability_id = SecureRandom.uuid_v7

    handler = Frameworks::CommandHandler.new
    handler.create_framework(framework_id, "Engineering")
    handler.add_role_family(framework_id, family_id, "Engineering")
    handler.add_role(framework_id, role_id, family_id, "Software Engineer", "E", "ic")
    handler.add_level(framework_id, level_id, role_id, 3, "Engineer III", "E3")
    handler.add_level(framework_id, SecureRandom.uuid_v7, role_id, 4, "Engineer IV", "E4")
    handler.add_capability_category(framework_id, category_id, "Thinking")
    handler.add_capability(framework_id, capability_id, SecureRandom.uuid_v7,
                           category_id, "Strategic Thinking")
    handler.set_behavioural_expectation(framework_id, SecureRandom.uuid_v7,
                                        SecureRandom.uuid_v7, capability_id, 3,
                                        "Identifies root causes.")
    handler.set_behavioural_expectation(framework_id, SecureRandom.uuid_v7,
                                        SecureRandom.uuid_v7, capability_id, 4,
                                        "Shapes system direction.")
    handler.publish_version(framework_id, "seed")

    @cap = FrameworkState::Capability.find_by!(capability_id: capability_id)
    [ framework_id, role_id, level_id ]
  end

  # The factory row is a read model with no event stream behind it, so an
  # outcome POST against it fails in the aggregate ("Session not defined")
  # and answers from the rescue branch — where the state pass-through looks
  # identical. Define and start the real stream so the success path is what
  # the assertions actually exercise.
  def start_session_stream
    handler = AssessmentCycles::CalibrationCommandHandler.new
    ActsAsTenant.with_tenant(@tenant) do
      Rails.configuration.event_store.with_metadata(tenant_id: @tenant.id) do
        handler.define_session(@session.id, @cycle.cycle_id, @cycle.framework_id,
                               @session.name, 1, facilitator_id: @facilitator.id,
                               participant_ids: [ @em.id ],
                               calibrant_person_ids: [ @report.id ])
        handler.start_session(@session.id, started_by_id: @facilitator.id)
      end
    end
  end

  # A second participant with their own report and evidence on the same
  # capability, so a rater filter that does nothing is distinguishable
  # from one that works.
  def seed_second_rater
    ActsAsTenant.with_tenant(@tenant) do
      other_em = create(:person, tenant: @tenant, name: "Raj Rater", manager: @facilitator)
      other_report = create(:person, tenant: @tenant, name: "Omar IC", manager: other_em)
      create(:person_framework_assignment, tenant: @tenant,
             person_id: other_report.id, framework_id: @cycle.framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: other_report.id, level_ordinal: 3)
      create(:assessment_level_rating, tenant: @tenant, cycle_id: @cycle.cycle_id,
             person_id: other_report.id, framework_id: @cycle.framework_id,
             capability_stable_id: @cap.stable_id, level_ordinal: 3,
             manager_rated_frequency: "some")
      create(:evidence_item, tenant: @tenant, person_id: other_report.id,
             framework_id: @cycle.framework_id, author_id: other_em.id,
             capability_stable_id: @cap.stable_id, level_ordinal: 3,
             content: "Ran the billing spike end to end.")
      create(:calibration_session_member, :participant, tenant: @tenant,
             session: @session, person_id: other_em.id)
      create(:calibration_session_member, tenant: @tenant,
             session: @session, person_id: other_report.id)
      [ other_em, other_report ]
    end
  end
end

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

      @cycle = create(:assessment_cycle, tenant: @tenant)
      create(:person_framework_assignment, tenant: @tenant,
             person_id: @report.id, framework_id: @cycle.framework_id)
      create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
             person_id: @report.id, level_ordinal: 3)

      category = create(:framework_capability_category, tenant: @tenant,
                        framework_id: @cycle.framework_id, name: "Thinking")
      @cap = create(:framework_capability, tenant: @tenant,
                    category_id: category.category_id, name: "Strategic Thinking")
      create(:framework_behavioural_expectation, tenant: @tenant,
             capability_id: @cap.capability_id, level_ordinal: 3,
             description: "Identifies root causes.")
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
    # attributed via an active rating delegation. Their peer feedback is
    # still not the facilitator's to read — EvidencePolicy would refuse it
    # on /assessments, and the session must not be a way around that.
    should "withhold evidence for a calibrant outside the facilitator's entitlement" do
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
    end

    should "render the compare tray for pinned people, dropping foreign pins" do
      get calibration_session_capability_path(
        @session, @cap.stable_id, view: "compare",
        compare: [ @report.id, SecureRandom.uuid_v7, @em.id ]
      )

      assert_response :success
      assert_includes response.body, "Compare (1)"
      assert_includes response.body, "Ivy IC"
      assert_includes response.body, "Unpin"
    end

    should "resolve pins before capping so stale ids can't squeeze out a live one" do
      stale = Array.new(CalibrationSessions::CapabilitiesController::MAX_COMPARE_PINS) { SecureRandom.uuid_v7 }

      get calibration_session_capability_path(
        @session, @cap.stable_id, view: "compare", compare: stale + [ @report.id ]
      )

      assert_includes response.body, "Compare (1)"
      assert_includes response.body, "Ivy IC"
    end

    should "carry the pane, the opened person, the pins and the filters through an outcome POST" do
      post calibration_session_rating_revisits_path(@session), params: {
        person_id: @report.id, capability_stable_id: @cap.stable_id,
        level_ordinal: 3, note: "Compare the pricing work with Omar's.",
        compare: [ @report.id ], view: "wall", wall_valence: "demonstrated"
      }

      assert_response :redirect
      assert_includes response.redirect_url, "compare%5B%5D=#{@report.id}"
      assert_includes response.redirect_url, "person=#{@report.id}"
      assert_includes response.redirect_url, "view=wall"
      assert_includes response.redirect_url, "wall_valence=demonstrated"
    end

    should "carry the same state through a flag POST, which names the person differently" do
      post calibration_session_expectation_flags_path(@session), params: {
        capability_stable_id: @cap.stable_id, level_ordinal: 3,
        reason: "Scope or altitude?", person: @report.id,
        compare: [ @report.id ], view: "compare"
      }

      assert_response :redirect
      assert_includes response.redirect_url, "person=#{@report.id}"
      assert_includes response.redirect_url, "compare%5B%5D=#{@report.id}"
      assert_includes response.redirect_url, "view=compare"
    end

    should "not error when an outcome POST carries a hash compare param" do
      post calibration_session_rating_revisits_path(@session), params: {
        person_id: @report.id, capability_stable_id: @cap.stable_id,
        level_ordinal: 3, note: "Malformed state.", compare: { "x" => "y" }
      }

      assert_response :redirect
      assert_not_includes response.redirect_url, "compare"
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

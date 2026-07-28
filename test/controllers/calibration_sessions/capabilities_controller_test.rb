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

    should "redirect for an unknown capability" do
      get calibration_session_capability_path(@session, SecureRandom.uuid_v7)
      assert_redirected_to calibration_session_path(@session)
    end

    should "render the evidence wall with reveal-gated items and filters" do
      get calibration_session_capability_path(@session, @cap.stable_id, view: "wall")

      assert_response :success
      assert_includes response.body, "1 item"
      # The detail half (name + text) is server-rendered but hidden until the
      # reveal choreography shows it.
      assert_includes response.body, "Led the pricing re-architecture"
      assert_includes response.body, 'data-reveal-role="detail"'
      assert_includes response.body, 'data-reveal-role="summary"'
      assert_includes response.body, "wall-filter-wall_level"
    end

    should "apply wall filters and echo them in the tab links" do
      get calibration_session_capability_path(@session, @cap.stable_id,
                                              view: "wall", wall_level: 4)

      assert_response :success
      assert_includes response.body, "0 items"
      assert_not_includes response.body, "Led the pricing re-architecture"
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
      # Pinned people count as revealed for the choreography controller.
      assert_includes response.body, @report.id
    end

    should "carry compare pins through an outcome POST redirect" do
      post calibration_session_rating_revisits_path(@session), params: {
        person_id: @report.id, capability_stable_id: @cap.stable_id,
        level_ordinal: 3, note: "Compare the pricing work with Omar's.",
        compare: [ @report.id ]
      }

      assert_response :redirect
      assert_includes response.redirect_url, "compare%5B%5D=#{@report.id}"
      assert_includes response.redirect_url, "person=#{@report.id}"
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
end

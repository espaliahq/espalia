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
        create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle, person_id: @report.id)
        create(:assessment_level_rating,
          tenant: @tenant, cycle_id: @cycle.cycle_id, person_id: @report.id,
          framework_id: @cycle.framework_id, capability_stable_id: SecureRandom.uuid_v7,
          level_ordinal: 2, manager_rated_frequency: "consistent",
          manager_rating_source: "seeded", source: "seeded")
      end

      get calibration_session_path(session_record)
      assert_response :success
      assert_includes response.body, "To confirm"
      assert_not_includes response.body, "In progress"
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
        [ @report, quinn_report ].each do |person|
          create(:assessment_cycle_enrollment, tenant: @tenant, cycle: @cycle,
                 person_id: person.id, level_ordinal: 3)
        end
        category = create(:framework_capability_category, tenant: @tenant,
                          framework_id: @cycle.framework_id, name: "Thinking")
        cap = create(:framework_capability, tenant: @tenant,
                     category_id: category.category_id, name: "Strategic Thinking")
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
               person_id: raj_report.id, level_ordinal: 3)
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

    should "say so on the strip and keep them off the board" do
      get calibration_session_path(@session_record)

      assert_response :success
      # Strip: the row stays (readiness is its job) but reads as a state,
      # not as zeroed measurements.
      assert_includes response.body, "No ratings yet"
      assert_select "td[colspan='5']", text: /No ratings yet/
      # Board: no legend swatch promising a dot that exists on no axis —
      # a footnote names them instead.
      assert_includes response.body, "Quinn Alderberry hasn&#39;t rated yet — not on the board."
      board = response.body[/Capability divergence.*?(?=PARTICIPANTS|Participants)/m]
      legend_names = board.scan(/rounded-full bg-\w+-600[^>]*><\/span>([^<]+)/).flatten if board
      assert_not_includes response.body.scan(/<div class="flex items-center gap-1\.5[^>]*>.*?<\/div>/m).join,
                          "Quinn Alderberry hasn&#39;t", "footnote is a sentence, not a legend entry"
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

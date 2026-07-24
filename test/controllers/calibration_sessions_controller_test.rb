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

  def define_session
    ActsAsTenant.with_tenant(@tenant) do
      result = Operations::CalibrationSessions::Define.call(
        context: AuthorizationContext.new(
          user: @facilitator_user,
          tenant_user: TenantUser.find_by(user: @facilitator_user),
          person: @facilitator
        ),
        params: {
          cycle_id: @cycle.cycle_id, name: "Engineering calibration",
          participant_ids: [ @em.id ], calibrant_person_ids: [ @report.id ]
        }
      )
      CalibrationSession.find(result[:session_id])
    end
  end
end

# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::ArchivesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @tenant = create(:tenant)
    @facilitator_user = create(:user)
    @em_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @facilitator = create(:person, tenant: @tenant, email: @facilitator_user.email, name: "Dana Dept")
      @em = create(:person, tenant: @tenant, email: @em_user.email, manager: @facilitator)
      @report = create(:person, tenant: @tenant, manager: @em)
      create(:tenant_user, tenant: @tenant, user: @facilitator_user, person: @facilitator)
      create(:tenant_user, tenant: @tenant, user: @em_user, person: @em)

      cycle = create(:assessment_cycle, tenant: @tenant)
      context = AuthorizationContext.new(
        user: @facilitator_user, tenant_user: TenantUser.find_by(user: @facilitator_user), person: @facilitator
      )
      @session_id = Operations::CalibrationSessions::Define.call(
        context: context,
        params: { cycle_id: cycle.cycle_id, name: "Engineering · H1",
                  participant_ids: [ @em.id ], calibrant_person_ids: [ @report.id ] }
      )[:session_id]
      @context = context
    end
  end

  def session_record
    ActsAsTenant.with_tenant(@tenant) { CalibrationSession.find(@session_id) }
  end

  def close!
    ActsAsTenant.with_tenant(@tenant) do
      Operations::CalibrationSessions::Close.call(context: @context, params: { session_id: @session_id })
    end
  end

  context "as the facilitator" do
    setup { sign_in @facilitator_user }

    should "archive a closed session and restore it" do
      close!

      post archive_calibration_session_path(@session_id)
      assert_redirected_to calibration_sessions_path
      assert_match(/archived/, flash[:notice])
      assert session_record.archived?

      post unarchive_calibration_session_path(@session_id)
      assert_redirected_to calibration_sessions_path
      assert_not session_record.archived?
      assert_equal "closed", session_record.status
    end

    should "go back where the action was taken" do
      close!
      post archive_calibration_session_path(@session_id),
           headers: { "HTTP_REFERER" => calibration_session_url(@session_id) }
      assert_redirected_to calibration_session_url(@session_id)
    end

    should "refuse to archive a session that isn't closed" do
      post archive_calibration_session_path(@session_id)

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_not session_record.archived?
    end
  end

  context "as a participant EM" do
    should "deny archive and restore" do
      close!
      sign_in @em_user

      post archive_calibration_session_path(@session_id)
      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_not session_record.archived?

      post unarchive_calibration_session_path(@session_id)
      assert_redirected_to root_path
    end
  end
end

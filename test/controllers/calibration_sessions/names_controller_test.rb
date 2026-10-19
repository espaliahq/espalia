# frozen_string_literal: true

require "test_helper"

class CalibrationSessions::NamesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  FRAME_HEADERS = { "Turbo-Frame" => "calibration-session-name" }.freeze

  setup do
    @tenant = create(:tenant)
    @facilitator_user = create(:user)
    @em_user = create(:user)

    ActsAsTenant.with_tenant(@tenant) do
      @facilitator = create(:person, tenant: @tenant, email: @facilitator_user.email)
      @em = create(:person, tenant: @tenant, email: @em_user.email, manager: @facilitator)
      create(:tenant_user, tenant: @tenant, user: @facilitator_user, person: @facilitator)
      create(:tenant_user, tenant: @tenant, user: @em_user, person: @em)
      @session = create(:calibration_session, :closed, tenant: @tenant,
                        facilitator_id: @facilitator.id, name: "Engineering · H1")
      # The aggregate needs a defined stream to rename.
      stream = EventStreamNaming.calibration_session_stream(@session.id, tenant: @tenant)
      Rails.configuration.event_store.append(
        AssessmentCycles::Events::CalibrationSessionDefined.new(
          data: { session_id: @session.id, cycle_id: @session.cycle_id, framework_id: @session.framework_id,
                  framework_version: 1, name: @session.name, facilitator_id: @facilitator.id,
                  participant_ids: [], calibrant_person_ids: [] },
          metadata: { tenant_id: @tenant.id }
        ),
        stream_name: stream
      )
    end
  end

  def session_name
    ActsAsTenant.with_tenant(@tenant) { @session.reload.name }
  end

  context "as the facilitator" do
    setup { sign_in @facilitator_user }

    should "rename from the pencil and answer with the frame" do
      patch name_calibration_session_path(@session), headers: FRAME_HEADERS,
            params: { calibration_session: { name: "  Engineering · H1 2026 " } }

      assert_response :success
      assert_equal "Engineering · H1 2026", session_name
      assert_includes response.body, %(id="calibration-session-name-#{@session.id}")
      assert_includes response.body, "Engineering · H1 2026"
    end

    should "refuse a blank name inline with 422, keeping the typed text" do
      patch name_calibration_session_path(@session), headers: FRAME_HEADERS,
            params: { calibration_session: { name: "   " } }

      assert_response :unprocessable_content
      assert_includes response.body, "Couldn’t save: the name can’t be blank"
      assert_includes response.body, %(data-editor-value="   ")
      assert_equal "Engineering · H1", session_name
    end

    should "rename from the index dialog and go back" do
      patch name_calibration_session_path(@session),
            params: { calibration_session: { name: "Renamed" } },
            headers: { "HTTP_REFERER" => calibration_sessions_url }

      assert_redirected_to calibration_sessions_url
      assert_equal "Renamed to “Renamed”.", flash[:notice]
      assert_equal "Renamed", session_name
    end

    should "refuse a blank name from the dialog with an alert" do
      patch name_calibration_session_path(@session), params: { calibration_session: { name: "" } }

      assert_redirected_to calibration_sessions_path
      assert_match(/can’t be blank/, flash[:alert])
    end
  end

  context "as a participant EM" do
    should "deny the rename" do
      sign_in @em_user
      patch name_calibration_session_path(@session), params: { calibration_session: { name: "Mine" } }

      assert_redirected_to root_path
      assert_equal "You are not authorized to perform this action.", flash[:alert]
      assert_equal "Engineering · H1", session_name
    end
  end
end

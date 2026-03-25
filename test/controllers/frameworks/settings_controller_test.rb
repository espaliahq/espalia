# frozen_string_literal: true

require "test_helper"

class Frameworks::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = create(:tenant)
    @admin_user = create(:user, password: "password123")
    @member_user = create(:user, password: "password123")
    @global_admin = create(:user, password: "password123", global_admin: true)

    ActsAsTenant.with_tenant(@tenant) do
      create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)
      create(:tenant_user, tenant: @tenant, user: @global_admin, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
    end
  end

  context "GET /frameworks/:framework_id/settings" do
    should "render settings page for tenant admin" do
      sign_in @admin_user
      get framework_settings_path(framework_id: @framework_id)

      assert_response :success
      assert_includes response.body, "Scoring Thresholds"
      assert_includes response.body, "Mastery Threshold"
      assert_includes response.body, "Meeting Expectations Threshold"
      assert_includes response.body, "Over-performance Cap"
      assert_includes response.body, "Deficit Threshold"
    end

    should "render settings page for global admin even if member role" do
      sign_in @global_admin
      get framework_settings_path(framework_id: @framework_id)

      assert_response :success
      assert_includes response.body, "Scoring Thresholds"
    end

    should "redirect non-admin members to framework page" do
      sign_in @member_user
      get framework_settings_path(framework_id: @framework_id)

      assert_redirected_to framework_path(@framework_id)
    end

    should "redirect unauthenticated users to sign in" do
      get framework_settings_path(framework_id: @framework_id)

      assert_redirected_to new_user_session_path
    end
  end

  context "PATCH /frameworks/:framework_id/settings" do
    should "update scoring thresholds with custom values" do
      sign_in @admin_user
      patch framework_settings_path(framework_id: @framework_id),
            params: { settings: {
              mastery_threshold: "1.25",
              meeting_expectation_threshold: "0.90",
              overperformance_cap: "2",
              deficit_threshold: "0.50"
            } }

      assert_redirected_to framework_settings_path(framework_id: @framework_id)

      ActsAsTenant.with_tenant(@tenant) do
        fw = FrameworkState::Framework.find_by!(framework_id: @framework_id)
        assert_equal BigDecimal("1.25"), fw.mastery_threshold
        assert_equal BigDecimal("0.90"), fw.meeting_expectation_threshold
        assert_equal 2, fw.overperformance_cap
        assert_equal BigDecimal("0.50"), fw.deficit_threshold
      end
    end

    should "set nullable fields to nil when values are blank (revert to default)" do
      sign_in @admin_user

      # First set custom values
      patch framework_settings_path(framework_id: @framework_id),
            params: { settings: {
              mastery_threshold: "1.25",
              meeting_expectation_threshold: "0.90",
              overperformance_cap: "2",
              deficit_threshold: "0.50"
            } }

      # Then revert mastery_threshold and meeting_expectation_threshold to defaults
      patch framework_settings_path(framework_id: @framework_id),
            params: { settings: {
              mastery_threshold: "",
              meeting_expectation_threshold: "",
              overperformance_cap: "2",
              deficit_threshold: "0.50"
            } }

      assert_redirected_to framework_settings_path(framework_id: @framework_id)

      ActsAsTenant.with_tenant(@tenant) do
        fw = FrameworkState::Framework.find_by!(framework_id: @framework_id)
        assert_nil fw.mastery_threshold
        assert_nil fw.meeting_expectation_threshold
      end
    end

    should "emit a ScoringThresholdsConfigured event" do
      sign_in @admin_user
      stream = ActsAsTenant.with_tenant(@tenant) { EventStreamNaming.framework_stream(@framework_id) }
      event_store = Rails.configuration.event_store
      events_before = event_store.read.stream(stream).to_a.size

      patch framework_settings_path(framework_id: @framework_id),
            params: { settings: {
              mastery_threshold: "1.20",
              meeting_expectation_threshold: "0.85",
              overperformance_cap: "1",
              deficit_threshold: "1.0"
            } }

      events_after = event_store.read.stream(stream).to_a
      new_events = events_after[events_before..]
      assert_equal 1, new_events.size
      assert_instance_of Frameworks::Events::ScoringThresholdsConfigured, new_events.first
    end

    should "redirect non-admin members" do
      sign_in @member_user
      patch framework_settings_path(framework_id: @framework_id),
            params: { settings: { mastery_threshold: "1.25", meeting_expectation_threshold: "0.90",
                                  overperformance_cap: "1", deficit_threshold: "1.0" } }

      assert_redirected_to framework_path(@framework_id)
    end

    should "redirect unauthenticated users to sign in" do
      patch framework_settings_path(framework_id: @framework_id),
            params: { settings: { mastery_threshold: "1.25", meeting_expectation_threshold: "0.90",
                                  overperformance_cap: "1", deficit_threshold: "1.0" } }

      assert_redirected_to new_user_session_path
    end
  end

  private

  def sign_in(user)
    post user_session_path, params: { user: { email: user.email, password: "password123" } }
  end
end

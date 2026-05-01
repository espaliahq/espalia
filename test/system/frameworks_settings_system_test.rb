# frozen_string_literal: true

require "application_system_test_case"

class FrameworksSettingsSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

  setup do
    @tenant = FactoryBot.create(:tenant)
    @admin_user = FactoryBot.create(:user, password: "password123")
    @member_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @admin_user, role: :admin)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @member_user, role: :member)

      handler = Frameworks::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test Framework")
    end

    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
  end

  context "settings page" do
    should "display all four scoring threshold settings" do
      sign_in @admin_user
      visit framework_settings_path(framework_id: @framework_id)

      assert_text "Settings"
      assert_text "Scoring Thresholds"
      assert_text "Mastery Threshold"
      assert_text "Meeting Expectations Threshold"
      assert_text "Over-performance Cap"
      assert_text "Deficit Threshold"
    end

    should "display human-friendly descriptions for each setting" do
      sign_in @admin_user
      visit framework_settings_path(framework_id: @framework_id)

      assert_text "performance ratio a person must reach"
      assert_text "minimum performance ratio"
      assert_text "levels above a person's assigned level"
      assert_text "weighted deficit above which a capability"
    end

    should "save custom values and show them on reload" do
      sign_in @admin_user
      visit framework_settings_path(framework_id: @framework_id)

      # Wait for all four setting-field controllers to connect before typing
      # or submitting — on slow CI runners, clicks fired while Stimulus is
      # still booting can be silently dropped, leaving the form unsubmitted.
      assert_selector "[data-controller~='setting-field'][data-connected]",
                      count: 4, visible: :all

      fill_in "settings[mastery_threshold]", with: "1.25"
      fill_in "settings[meeting_expectation_threshold]", with: "0.90"
      fill_in "settings[overperformance_cap]", with: "2"
      fill_in "settings[deficit_threshold]", with: "0.50"

      # Retry the submit once if the first click was lost on slow CI.
      click_button_with_js_fallback("Save settings", expect_text: "Scoring settings updated")

      assert_field "settings[mastery_threshold]", with: "1.25"
      assert_field "settings[meeting_expectation_threshold]", with: "0.9"
      assert_field "settings[overperformance_cap]", with: "2"
      assert_field "settings[deficit_threshold]", with: "0.5"
    end

    should "show settings link on framework show page for admins" do
      sign_in @admin_user
      visit framework_path(@framework_id)

      assert_link "Settings"
    end

    should "not show settings link on framework show page for non-admins" do
      sign_in @member_user
      visit framework_path(@framework_id)

      assert_no_link "Settings"
    end

    should "redirect non-admin members away from settings" do
      sign_in @member_user
      visit framework_settings_path(framework_id: @framework_id)

      assert_current_path root_path
      assert_text "You are not authorized to perform this action"
    end
  end

  private

  def sign_in(user)
    sign_in_as(user)
  end
end

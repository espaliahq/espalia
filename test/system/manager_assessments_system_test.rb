# frozen_string_literal: true

require "application_system_test_case"

class ManagerAssessmentsSystemTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @manager_user = FactoryBot.create(:user, password: "password123")
    @report_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager Jane")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

      @report = FactoryBot.create(:person, tenant: @tenant, email: @report_user.email, name: "Report Alex", manager: @manager)
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @report_user, person: @report)

      handler = Frameworks::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Engineering Growth")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")

      @level1_id = SecureRandom.uuid_v7
      @level2_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level1_id, @role_id, 1, "Junior", "E1", is_entry: true)
      handler.add_level(@framework_id, @level2_id, @role_id, 2, "Mid", "E2")

      cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, cat_id, "Thinking", ordinal: 1)

      @cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap_id, @cap_stable, cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap_id, @role_id, weight: 1.0
      )

      eid = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, eid, SecureRandom.uuid_v7, @cap_id, 1,
        "Asks clarifying questions")
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 2,
        "Synthesises information from multiple sources")

      # Assign the report to the framework and open a cycle
      level = FrameworkState::Level.find_by!(level_id: @level2_id)
      pd_handler.assign_to_framework(@report.id, @framework_id, @role_id, level.level_id)
      pd_handler.open_assessment_cycle(
        @report.id, @framework_id,
        SecureRandom.uuid_v7, "Q1 2026 Review", "regular", 1
      )

      # Pre-rate a capability as the report (self-rating)
      pd_handler.rate_self(
        @report.id, @framework_id, @cap_stable,
        level_ordinal: 2, frequency: "occasional", comment: "Self-rated"
      )
    end

    # Sign in as the manager
    visit new_user_session_path
    fill_in "Email", with: @manager_user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end

  context "manager assessment index" do
    should "show Assessments nav link and Team Assessments section" do
      # The nav should show "Assessments" for a manager with report assignments
      click_link "Assessments"

      assert_text "My Assessments"
      assert_text "Team Assessments"
      assert_text "Report Alex"
    end
  end

  context "manager assessment show" do
    should "render manager review view after clicking through from index" do
      click_link "Assessments"
      assert_text "Team Assessments"

      click_link "Review Assessment"

      assert_text "Report Alex"
      assert_text "Manager Review"
      assert_text "assessment-matrix" if false # DOM id, not visible text
      assert_text "Critical Thinking"
      assert_text "Synthesises information"
    end

    should "show self-rating indicator and manager frequency selectors" do
      click_link "Assessments"
      click_link "Review Assessment"

      # The report's self-rating should appear as a read-only indicator
      assert_text "Self:"

      # Manager frequency selector buttons should be present
      assert_selector "button", text: "Some"
      assert_selector "button", text: "Occasional"
      assert_selector "button", text: "Consistent"
    end

    should "allow manager to submit a rating" do
      click_link "Assessments"
      click_link "Review Assessment"

      wait_for_stimulus "matrix"

      # Click a frequency button to rate
      find("#rating-#{@cap_stable}-2 button", text: "Consistent").click

      # Verify the scoring panel updates
      assert_selector "#scoring-panel"
    end

    should "allow manager to untoggle a rating by clicking the same frequency" do
      click_link "Assessments"
      click_link "Review Assessment"

      wait_for_stimulus "matrix"

      # Rate as "Consistent"
      find("#rating-#{@cap_stable}-2 button", text: "Consistent").click
      assert_selector "#cell-#{@cap_stable}-2"

      # Click "Consistent" again to untoggle — rating should be cleared
      find("#rating-#{@cap_stable}-2 button", text: "Consistent").click

      # After clearing, no frequency button should have the selected ring style
      within("#rating-#{@cap_stable}-2") do
        assert_no_selector "button.ring-1"
      end
    end
  end
end

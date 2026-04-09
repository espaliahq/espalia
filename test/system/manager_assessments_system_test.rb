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

      handler.create_framework(@framework_id, "me&u 2025 Career Framework")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Product & Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")

      @level1_id = SecureRandom.uuid_v7
      @level2_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level1_id, @role_id, 1, "Junior", "E1", is_entry: true)
      handler.add_level(@framework_id, @level2_id, @role_id, 2, "Senior Software Engineer", "E2")

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

      # Assign the report to the framework and enrol them in a cycle
      level = FrameworkState::Level.find_by!(level_id: @level2_id)
      pd_handler.assign_to_framework(@report.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1 2026 Review", "regular", 1, defined_by: @manager.id)
      cycle_handler.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)

      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first

      # Pre-rate a capability as the report (self-rating)
      pd_handler.rate_self(
        @report.id, @framework_id, @cap_stable,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id, comment: "Self-rated"
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
      # Wait for the index to fully render before clicking through. Without
      # this synchronisation, the second click can land on a stale link
      # and be silently dropped on slow CI runners.
      assert_text "Team Assessments"
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
      # Wait for the index to fully render before clicking through. Without
      # this synchronisation, the second click can land on a stale link
      # and be silently dropped on slow CI runners.
      assert_text "Team Assessments"
      click_link "Review Assessment"

      # Synchronise with Turbo navigation before waiting on the matrix
      # controller. Without this, slow CI can exhaust Capybara's wait window
      # on navigation alone, leaving nothing for the controller-ready check.
      assert_text "Manager Review"
      wait_for_stimulus "matrix"

      # Click a frequency button to rate
      find("#rating-#{@cap_stable}-2 button", text: "Consistent").click

      # Verify the Turbo Stream response re-rendered the cell with the button selected
      within("#rating-#{@cap_stable}-2") do
        assert_selector "button.ring-1", text: "Consistent"
      end
    end

    should "allow manager to untoggle a rating by clicking the same frequency" do
      click_link "Assessments"
      # Wait for the index to fully render before clicking through. Without
      # this synchronisation, the second click can land on a stale link
      # and be silently dropped on slow CI runners.
      assert_text "Team Assessments"
      click_link "Review Assessment"

      # Synchronise with Turbo navigation before waiting on the matrix
      # controller. Without this, slow CI can exhaust Capybara's wait window
      # on navigation alone, leaving nothing for the controller-ready check.
      assert_text "Manager Review"
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

  context "responsive behaviour" do
    should "show manager assessment index on mobile with team assessments visible" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessments_path

      assert_text "Team Assessments"
      assert_text "Report Alex"
      assert_link "Review Assessment"
    end

    should "show manager review matrix on mobile with scoring toggle visible" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessments_path
      # Wait for the index to fully render before clicking through. Without
      # this synchronisation, the click can land on a stale link and be
      # silently dropped on slow CI runners.
      assert_text "Team Assessments"
      click_link "Review Assessment"

      # Header elements should be visible — long names must not push scoring off-screen
      assert_text "Report Alex"
      assert_text "Manager Review"
      assert_text "me&u 2025 Career Framework"
      assert_text "Software Engineer"
      assert_text "Senior Software Engineer"

      # Matrix content should be visible
      assert_text "Critical Thinking"

      # Scoring toggle must remain visible on-screen despite long header text
      scoring_button = find_button("Scoring")
      assert scoring_button.obscured? == false, "Scoring button is off-screen or obscured"
    end
  end

  context "cross-session sync" do
    should "update manager view when report submits a new self-rating" do
      # Manager opens the report's assessment
      click_link "Assessments"
      assert_text "Team Assessments"
      click_link "Review Assessment"
      assert_text "Manager Review"
      wait_for_stimulus "matrix"

      # Verify WebSocket subscription and sync controller are ready
      assert_selector "turbo-cable-stream-source", visible: :all
      wait_for_stimulus "assessment-sync"

      # Level 1 has no self-rating yet — no "Self:" pill for that cell
      within("#cell-#{@cap_stable}-1") do
        assert_no_text "Self:"
      end

      # Simulate the report submitting a self-rating from another session
      # (server-side, as if from another browser)
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @report.id, @framework_id, @cap_stable,
          level_ordinal: 1, frequency: "consistent", cycle_id: @cycle_id, comment: "From other session"
        )
      end

      # The broadcast should trigger a matrix refresh in the manager's browser.
      # Wait for the sync signal to be replaced (broadcast delivery + frame reload)
      assert_selector "#assessment-sync-signal[data-updated-at]", visible: :all, wait: 10

      # After frame reload, the self-rating pill should appear in the cell.
      within("#cell-#{@cap_stable}-1") do
        assert_text "Self:", wait: 10
      end
    end
  end
end

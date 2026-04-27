# frozen_string_literal: true

require "application_system_test_case"

# Exercises the alignment flow: from a manager's view of a direct report's
# assessment, the manager switches into alignment mode via the "Start alignment"
# pill and records an agreed frequency per capability×level. Both parties should
# be able to align (see policy tests); this system test focuses on the manager
# path — mirrors manager_assessments_system_test.rb.
class AlignmentAssessmentsSystemTest < ApplicationSystemTestCase
  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @manager_user = FactoryBot.create(:user, password: "password123")
    @report_user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @manager = FactoryBot.create(:person, tenant: @tenant, email: @manager_user.email, name: "Manager Jane")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @manager_user, person: @manager)

      @report = FactoryBot.create(:person, tenant: @tenant, email: @report_user.email, name: "Report Alex",
        manager: @manager)
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

      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 1,
        "Asks clarifying questions")
      handler.set_behavioural_expectation(@framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 2,
        "Synthesises information from multiple sources")

      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level2_id)
      pd_handler.assign_to_framework(@report.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1 2026 Review", "regular", 1, defined_by: @manager.id)
      cycle_handler.enroll(@cycle_id, @report.id, enrolled_by: @manager.id)

      @report_assignment = PersonFrameworkAssignment.for_person(@report.id).first

      # Pre-rate as both self and manager so alignment has something to agree on
      pd_handler.rate_self(
        @report.id, @framework_id, @cap_stable,
        level_ordinal: 2, frequency: "occasional", cycle_id: @cycle_id, comment: "Self-rated"
      )
      pd_handler.rate_as_manager(
        @report.id, @framework_id, @cap_stable,
        level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id, comment: "Manager-rated"
      )
    end

    visit new_user_session_path
    fill_in "Email", with: @manager_user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end

  context "manager enters alignment mode" do
    should "show Start alignment pill on the manager view" do
      visit assessment_path(@report_assignment)
      assert_text "Manager Review"
      assert_link "Start alignment"
    end

    should "switch into Aligning mode and expose alignment frequency selectors" do
      visit assessment_path(@report_assignment)
      click_with_retry(expect_text: "Aligning") { click_link "Start alignment" }

      wait_for_stimulus "matrix"
      assert_text "Report Alex"
      assert_text "Critical Thinking"
      assert_selector "button", text: "Consistent"
      assert_link "Exit alignment"
    end

    should "record an alignment when a frequency is clicked" do
      visit assessment_path(@report_assignment, mode: "alignment")
      assert_text "Aligning"
      wait_for_stimulus "matrix"

      find("#rating-#{@cap_stable}-2 button", text: "Consistent").click

      within("#rating-#{@cap_stable}-2") do
        assert_selector "button.ring-1", text: "Consistent"
      end

      # Verify an AssessmentAligned event landed on the person-development stream
      stream_name = "tenant-#{@tenant.id}/PersonDev-#{@report.id}-#{@framework_id}"
      events = Rails.configuration.event_store.read.stream(stream_name).to_a
      assert events.any? { |e| e.event_type.include?("AssessmentAligned") },
        "Expected an AssessmentAligned event on stream #{stream_name}"
    end
  end

  context "in-frame navigation preserves alignment mode" do
    should "render category tab links carrying mode=alignment" do
      visit assessment_path(@report_assignment, mode: "alignment")
      assert_text "Aligning"
      wait_for_stimulus "matrix"

      tab_links = page.all("nav#category-tabs a", visible: :all)
      assert tab_links.any?, "Expected at least one category tab link"
      tab_links.each do |link|
        assert_includes link[:href], "mode=alignment",
          "Category tab link #{link[:href]} should preserve mode=alignment"
      end
    end

    should "render scoring-panel category links carrying mode=alignment" do
      visit assessment_path(@report_assignment, mode: "alignment")
      assert_text "Aligning"
      wait_for_stimulus "matrix"

      panel_links = page.all("#scoring-panel a", visible: :all)
      assert panel_links.any?, "Expected at least one scoring-panel category link"
      panel_links.each do |link|
        assert_includes link[:href], "mode=alignment",
          "Scoring-panel link #{link[:href]} should preserve mode=alignment"
      end
    end
  end

  context "exiting alignment mode" do
    should "return to Manager Review after clicking Exit alignment" do
      visit assessment_path(@report_assignment, mode: "alignment")
      assert_text "Aligning"

      click_with_retry(expect_text: "Manager Review") { click_link "Exit alignment" }
      assert_no_link "Exit alignment"
      assert_link "Start alignment"
    end
  end

  context "responsive behaviour" do
    should "render alignment view with Scoring toggle visible on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@report_assignment, mode: "alignment")

      assert_text "Aligning"
      assert_text "Critical Thinking"
      scoring_button = find_button("Scoring")
      assert scoring_button.obscured? == false, "Scoring button is off-screen or obscured in alignment mode"
    end
  end
end

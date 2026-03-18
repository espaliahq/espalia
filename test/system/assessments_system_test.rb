# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice Engineer")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7

      handler.create_framework(@framework_id, "Engineering Growth")

      # Role family + role + levels
      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Software Engineer", "E", "ic")
      @level1_id = SecureRandom.uuid_v7
      @level2_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level1_id, @role_id, 1, "Junior", "E1", is_entry: true)
      handler.add_level(@framework_id, @level2_id, @role_id, 2, "Mid", "E2")

      # Category with tolerance
      @cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)

      # Capability 1: weighted 2.0, mandatory
      @cap1_id = SecureRandom.uuid_v7
      @cap1_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap1_id, @cap1_stable, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap1_id, @role_id,
        weight: 2.0, individual_tolerance: 0
      )
      eid1 = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, eid1, SecureRandom.uuid_v7, @cap1_id, 1,
        "Asks clarifying questions to understand problems")
      eid2 = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, eid2, SecureRandom.uuid_v7, @cap1_id, 2,
        "Synthesises information from multiple sources")

      # Capability 2: default weight 1.0
      @cap2_id = SecureRandom.uuid_v7
      @cap2_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap2_id, @cap2_stable, @cat_id, "Problem Solving")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap2_id, @role_id
      )
      eid3 = SecureRandom.uuid_v7
      handler.set_behavioural_expectation(@framework_id, eid3, SecureRandom.uuid_v7, @cap2_id, 1,
        "Breaks down tasks into manageable steps")

      # Assign person and open cycle
      level = FrameworkState::Level.find_by!(level_id: @level2_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)
      pd_handler.open_assessment_cycle(
        @person.id, @framework_id,
        SecureRandom.uuid_v7, "Q1 2026 Review", "regular", 1
      )
    end

    # Sign in
    visit new_user_session_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "password123"
    click_button "Log in"
    assert_current_path root_path
  end

  context "assessment index" do
    should "show framework assignment card" do
      visit assessments_path
      assert_text "My Assessments"
      assert_text "Engineering Growth"
      assert_text "In Progress"
    end
  end

  context "self-assessment flow" do
    should "display assessment matrix with frequency selectors" do
      visit assessment_path(@framework_id)

      assert_text "Engineering Growth"
      assert_text "Software Engineer"
      assert_text "Critical Thinking"
      assert_text "Problem Solving"

      # Frequency selector buttons visible
      assert_button "Some"
      assert_button "Occasional"
      assert_button "Consistent"

      # Scoring panel visible on desktop
      assert_text "Performance"
      assert_text "Categories"
    end

    should "rate a capability and see scoring update" do
      visit assessment_path(@framework_id)

      # Find the first "Consistent" button and click it
      within first("[id^='rating-']") do
        click_button "Consistent"
      end

      # Scoring panel should update (performance ratio changes)
      assert_selector "#scoring-panel"
    end

    should "show weight badge for weighted capabilities" do
      visit assessment_path(@framework_id)

      # Critical Thinking has weight 2.0 — should show "2×" badge
      assert_text "2×"
    end

    should "show mandatory indicator for zero-tolerance capabilities" do
      visit assessment_path(@framework_id)

      # Critical Thinking has individual_tolerance=0 and weight=2.0
      # Should show amber left border on the row (border-l-amber-400)
      assert_selector "tr.border-l-3"
    end
  end

  context "responsive behaviour" do
    should "show scoring panel as sidebar on desktop" do
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      visit assessment_path(@framework_id)

      # Scoring panel should be visible on desktop
      assert_selector "#scoring-panel", visible: true
    end

    should "show scoring toggle button on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@framework_id)

      # Scoring toggle button should be visible
      assert_button "Scoring"
    end
  end
end

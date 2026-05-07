# frozen_string_literal: true

require "application_system_test_case"

# Exercises the alignment flow: from a manager's view of a direct report's
# assessment, the manager starts alignment via the "Start alignment" button.
# Once started, the assessment view automatically renders in alignment mode
# for both parties — there is no opt-in/opt-out toggle. Both parties should
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

      # NOTE: alignment is NOT pre-started in setup. Tests that need an
      # already-aligning state call seed_alignment_started! explicitly.
    end

    sign_in_as(@manager_user)
  end

  context "manager starts alignment" do
    should "show a Start alignment button on the manager view before alignment begins" do
      visit assessment_path(@report_assignment)
      assert_selector "h1", text: "Report Alex"
      assert_button "Start alignment"
      assert_no_link "Continue alignment"
      assert_no_link "Exit alignment"
    end

    should "POST to alignment_start when the button is clicked (auto-confirmed) and switch into Aligning" do
      visit assessment_path(@report_assignment)
      assert_selector "h1", text: "Report Alex"

      click_with_retry(expect_text: "Aligning") do
        auto_confirm { click_button "Start alignment" }
      end

      assert_no_button "Start alignment"
      assert_button "Mark alignment complete"
    end

    should "auto-align cells where self and manager already agree, leaving disagreements for the conversation" do
      # Set up two cells: cap_stable at L2 disagrees (self=occasional, mgr=consistent
      # from the parent setup), and a SECOND cell at L1 where both rate "consistent".
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.rate_self(
          @report.id, @framework_id, @cap_stable,
          level_ordinal: 1, frequency: "consistent", cycle_id: @cycle_id
        )
        PersonDevelopment::CommandHandler.new.rate_as_manager(
          @report.id, @framework_id, @cap_stable,
          level_ordinal: 1, frequency: "consistent", cycle_id: @cycle_id
        )
      end

      visit assessment_path(@report_assignment)
      click_with_retry(expect_text: "Aligning") do
        auto_confirm { click_button "Start alignment" }
      end

      stream = "tenant-#{@tenant.id}/PersonDev-#{@report.id}-#{@framework_id}"
      events = Rails.configuration.event_store.read.stream(stream).to_a
      auto_aligned = events.grep(PersonDevelopment::Events::AssessmentAligned)
      assert_equal 1, auto_aligned.length, "expected exactly one auto-aligned event for the L1 match"
      assert_equal 1, auto_aligned.first.data[:level_ordinal]
      assert_equal "consistent", auto_aligned.first.data[:aligned_frequency]
      assert_match(/Auto-aligned/, auto_aligned.first.data[:comment])

      ActsAsTenant.with_tenant(@tenant) do
        l1 = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @report.id,
          capability_stable_id: @cap_stable, level_ordinal: 1
        )
        l2 = AssessmentLevelRating.find_by(
          cycle_id: @cycle_id, person_id: @report.id,
          capability_stable_id: @cap_stable, level_ordinal: 2
        )
        assert_equal "consistent", l1.aligned_frequency
        assert_nil l2.aligned_frequency
      end
    end

    should "render alignment frequency selectors once aligning" do
      seed_alignment_started!
      visit assessment_path(@report_assignment)
      wait_for_stimulus "matrix"

      assert_text "Report Alex"
      assert_text "Critical Thinking"
      assert_selector "button", text: "Consistent"
      assert_no_link "Exit alignment"
      assert_no_link "Continue alignment"
    end

    should "record an alignment when a frequency is clicked" do
      seed_alignment_started!
      visit assessment_path(@report_assignment)
      assert_text "Aligning"
      wait_for_stimulus "matrix"

      click_rating_frequency("#rating-#{@cap_stable}-2", "Consistent")

      within("#rating-#{@cap_stable}-2") do
        assert_selector "button.ring-1", text: "Consistent"
      end

      stream_name = "tenant-#{@tenant.id}/PersonDev-#{@report.id}-#{@framework_id}"
      events = Rails.configuration.event_store.read.stream(stream_name).to_a
      assert events.any? { |e| e.event_type.include?("AssessmentAligned") },
        "Expected an AssessmentAligned event on stream #{stream_name}"
    end
  end

  context "manager view during alignment" do
    setup { seed_alignment_started! }

    should "render in alignment mode automatically (no Start button, no toggle links)" do
      visit assessment_path(@report_assignment)
      assert_text "Aligning"
      assert_no_button "Start alignment"
      assert_no_link "Continue alignment"
      assert_no_link "Exit alignment"
    end

    should "render the alignment frequency selector as the interactive primary cell" do
      visit assessment_path(@report_assignment)
      wait_for_stimulus "matrix"

      # In alignment mode the primary cell is the aligned selector (buttons
      # present). Self/manager remain frozen at the policy/aggregate layer —
      # the assessee/manager simply no longer have any interactive control
      # over those individual perspectives in the UI.
      within("#rating-#{@cap_stable}-2") do
        assert_selector "button", text: "Consistent"
      end
    end
  end

  context "assessee experience during alignment" do
    setup do
      seed_alignment_started!

      Capybara.reset_sessions!
      sign_in_as(@report_user)
    end

    should "render in alignment mode automatically with no toggle affordances" do
      visit assessment_path(@report_assignment)
      assert_text "Aligning"
      assert_no_button "Start alignment"
      assert_no_link "Continue alignment"
      assert_no_link "Exit alignment"
    end

    should "render the alignment frequency selector as the interactive primary cell" do
      visit assessment_path(@report_assignment)
      wait_for_stimulus "matrix"

      within("#rating-#{@cap_stable}-2") do
        assert_selector "button", text: "Consistent"
      end
    end
  end

  context "manager marks alignment complete" do
    setup { seed_alignment_started! }

    should "show 'Mark alignment complete' whenever alignment is in progress" do
      visit assessment_path(@report_assignment)
      assert_text "Aligning"
      assert_button "Mark alignment complete"
    end

    should "complete alignment, flip the badge to Aligned, and freeze alignment cells" do
      visit assessment_path(@report_assignment)
      assert_text "Aligning"

      click_with_retry(expect_text: "Aligned") do
        auto_confirm { click_button "Mark alignment complete" }
      end
      assert_no_button "Mark alignment complete"

      # The alignment cell selectors should now be read-only bars (no buttons).
      visit assessment_path(@report_assignment)
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
      wait_for_stimulus "matrix"
      within("#cell-#{@cap_stable}-2") do
        assert_no_selector "button"
      end
    end
  end

  context "responsive behaviour" do
    setup { seed_alignment_started! }

    should "render alignment view with Scoring toggle visible on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@report_assignment)

      assert_text "Aligning"
      assert_text "Critical Thinking"
      scoring_button = find_button("Scoring")
      assert scoring_button.obscured? == false, "Scoring button is off-screen or obscured in alignment mode"
    end
  end

  private

  # Server-side seed: opens alignment for the cycle (sets participant to `aligning`).
  # Tests that need to start from an in-progress alignment use this; tests that
  # exercise the start-alignment UI flow do NOT.
  def seed_alignment_started!
    ActsAsTenant.with_tenant(@tenant) do
      PersonDevelopment::CommandHandler.new.start_alignment(
        @report.id, @framework_id, @cycle_id, started_by_id: @manager.id
      )
    end
  end
end

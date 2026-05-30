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

      # Publish v1 so shape-changing events land in the read model
      handler.publish_version(@framework_id, "test")

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
    sign_in_as(@manager_user)
  end

  context "manager assessment index" do
    should "show Assessments nav link and Team Assessments section" do
      # The nav should show "Assessments" for a manager with report assignments
      click_link_with_js_fallback("Assessments", expect_text: "Team Assessments")

      assert_text "My Assessments"
      assert_text "Report Alex"
    end
  end

  context "manager assessment show" do
    should "render manager review view after clicking through from index" do
      click_link_with_js_fallback("Assessments", expect_text: "Team Assessments")

      # "Critical Thinking" only renders on the manager-review (show) page —
      # using the team-list's "Report Alex" as the wait target leads to a
      # false-positive landed check, because that name is visible on both
      # the index (team list) and the show (h1) pages.
      click_link_with_js_fallback("Review Assessment", expect_text: "Critical Thinking")
      assert_selector "h1", text: "Report Alex"
      assert_text "Critical Thinking"

      # Every card auto-focuses on the person's current level, so the
      # level-2 expectation renders without any extra navigation.
      assert_text "Synthesises information"
    end

    should "address the assessee by name in the hero verdict" do
      # Pre-rate as manager so the verdict triggers an "On target" headline,
      # which is where the second-person wording leaks through.
      ActsAsTenant.with_tenant(@tenant) do
        pd_handler = PersonDevelopment::CommandHandler.new
        pd_handler.rate_as_manager(
          @report.id, @framework_id, @cap_stable,
          level_ordinal: 2, frequency: "consistent", cycle_id: @cycle_id
        )
      end

      visit assessment_path(@report_assignment)
      assert_selector "h1", text: "Report Alex"
      within("#scoring-panel") do
        # The hero verdict should refer to the assessee in third person
        # (first name), not "You're tracking on target"
        assert_no_text "You're"
        assert_no_text "you're"
        assert_text "Report is tracking on target."
      end
    end

    should "not render a redundant secondary sub-strip below the chip row" do
      # The old design rendered a "Self:" sub-strip of tiny dots under
      # the manager's chip row. That sub-strip is gone — the per-chip
      # divergence marker covers the signal at strip level. Secondary
      # bars still appear INSIDE the auto-focused expansion panel, so
      # we assert there's no stray sub-strip *between* the chip row and
      # the expansion (i.e. the chip strip's parent has no sibling
      # ".self-sub-strip" / ".mgr-sub-strip" element).
      visit assessment_path(@report_assignment)
      assert_selector "h1", text: "Report Alex"

      assert_no_selector "[data-self-sub-strip]"
      assert_no_selector "[data-mgr-sub-strip]"
      assert_no_selector "[data-agreed-sub-strip]"
    end

    should "render the inline frequency pill in the focused card's expansion panel" do
      visit assessment_path(@report_assignment, capability: @cap_stable)
      assert_selector "h1", text: "Report Alex"

      # The pill is an aria-haspopup button — opening it reveals the
      # four options + Clear inside the popover.
      assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']"
      open_pill_popover("#rating-#{@cap_stable}-2")
      within("#rating-#{@cap_stable}-2 [role='menu']") do
        assert_selector "[role='menuitem']", text: "Some of the time"
        assert_selector "[role='menuitem']", text: "Most of the time"
        assert_selector "[role='menuitem']", text: "Consistently"
      end
    end

    should "allow manager to submit a rating" do
      visit assessment_path(@report_assignment, capability: @cap_stable)
      assert_selector "h1", text: "Report Alex"
      wait_for_stimulus "matrix"

      click_rating_frequency("#rating-#{@cap_stable}-2", "Consistently")

      # Pill's visible label updates to the picked phrase.
      assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']", text: "Consistently"
    end

    should "allow manager to clear a rating via the popover Clear option" do
      visit assessment_path(@report_assignment, capability: @cap_stable)
      assert_selector "h1", text: "Report Alex"
      wait_for_stimulus "matrix"

      click_rating_frequency("#rating-#{@cap_stable}-2", "Consistently")
      assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']", text: "Consistently"

      # Open popover and pick Clear rating.
      open_pill_popover("#rating-#{@cap_stable}-2")
      page.execute_script(<<~JS, @cap_stable)
        const stable = arguments[0];
        const wrapper = document.querySelector("#rating-" + stable + "-2");
        const items = Array.from(wrapper.querySelectorAll("[role='menuitem']"));
        const item = items.find(b => b.textContent.trim().includes("Clear"));
        item?.closest("form")?.requestSubmit(item);
      JS

      # Pill returns to the un-rated label.
      assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']", text: "Not rated"
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

    should "show manager review on mobile with header elements visible" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@report_assignment)
      assert_selector "h1", text: "Report Alex"

      # Header elements should remain visible on mobile
      assert_text "Senior Software Engineer"
      assert_text "E2"

      # Matrix content should be visible
      assert_text "Critical Thinking"
    end
  end

  context "cross-session sync" do
    should "update manager view when report submits a new self-rating" do
      visit assessment_path(@report_assignment)
      assert_selector "h1", text: "Report Alex"
      wait_for_stimulus "matrix"

      # Verify WebSocket subscription and sync controller are ready
      assert_selector "turbo-cable-stream-source", visible: :all
      wait_for_stimulus "assessment-sync"

      # Level 1 has no self-rating yet — check the level chip for level 1
      # doesn't show a Self: indicator
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

      # After frame reload, the self-rating indicator should appear.
      # In the card layout the level strip shows secondary perspective dots.
      # The level chip for level 1 should now show it's rated.
      assert_selector "#cell-#{@cap_stable}-1", wait: 10
    end
  end
end

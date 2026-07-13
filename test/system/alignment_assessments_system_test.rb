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

      auto_confirm do
        page.execute_script(<<~JS)
          const btn = Array.from(document.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Start alignment");
          btn?.closest("form")?.requestSubmit(btn);
        JS
      end
      assert_text "Aligning"

      assert_no_button "Start alignment"
      # The single current-level cell is in disagreement (no agreed value
      # yet), so the completion control renders gated.
      assert_button "Mark alignment complete", disabled: true
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
      auto_confirm do
        page.execute_script(<<~JS)
          const btn = Array.from(document.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Start alignment");
          btn?.closest("form")?.requestSubmit(btn);
        JS
      end
      assert_text "Aligning"

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

    should "render the inline alignment pill once aligning" do
      seed_alignment_started!
      visit assessment_path(@report_assignment, capability: @cap_stable)
      wait_for_stimulus "matrix"

      assert_text "Report Alex"
      assert_text "Critical Thinking"
      assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']"
      assert_no_link "Exit alignment"
      assert_no_link "Continue alignment"
    end

    should "record an alignment when a frequency is picked from the pill" do
      seed_alignment_started!
      visit assessment_path(@report_assignment, capability: @cap_stable)
      assert_text "Aligning"
      wait_for_stimulus "matrix"

      click_rating_frequency("#rating-#{@cap_stable}-2", "Consistent")

      assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']", text: "Consistently"

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

    should "render the alignment pill as the interactive primary control" do
      visit assessment_path(@report_assignment, capability: @cap_stable)
      wait_for_stimulus "matrix"

      # In alignment mode the primary control is the aligned pill (an
      # aria-haspopup button). Self/manager remain frozen at the
      # policy/aggregate layer — they have no interactive control here.
      assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']"
    end

    should "lead with the manager's own perspective in the split chip and hero" do
      # Self rated "occasional" (green), manager "consistent" (blue) at L2 —
      # they disagree, so the cell isn't auto-aligned and the chip splits.
      # The viewer (manager) must see their OWN rating top-left here, exactly
      # as in the plain manager view (pinned in manager_assessments_system_test),
      # so the corner doesn't jump sides between the two surfaces.
      visit assessment_path(@report_assignment, capability: @cap_stable)
      wait_for_stimulus "matrix"

      # Top-left overlay slice is the manager's "consistent" (blue-500);
      # the base (bottom-right) is the report's "occasional" (green-500).
      assert_selector "#cell-#{@cap_stable}-2 [data-split].bg-blue-500", visible: :all
      assert_selector "#cell-#{@cap_stable}-2.bg-green-500"

      # Hero secondary percentages lead with the viewer's own — "Mgr:" first.
      percents = find("#hero-secondary-percents", visible: :all).text
      assert percents.index("Mgr:") < percents.index("Self:"),
        "expected Mgr before Self in '#{percents}'"
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

    should "render the alignment pill as the interactive primary control" do
      visit assessment_path(@report_assignment, capability: @cap_stable)
      wait_for_stimulus "matrix"

      assert_selector "#rating-#{@cap_stable}-2 button[aria-haspopup='menu']"
    end

    should "lead with the assessee's own perspective in the split chip and hero" do
      # Same cell, viewed by the assessee: their OWN "occasional" (green)
      # rating leads top-left, the manager's "consistent" (blue) is
      # bottom-right — the mirror of the manager's view of the same cell.
      visit assessment_path(@report_assignment, capability: @cap_stable)
      wait_for_stimulus "matrix"

      assert_selector "#cell-#{@cap_stable}-2 [data-split].bg-green-500", visible: :all
      assert_selector "#cell-#{@cap_stable}-2.bg-blue-500"

      # Hero secondary percentages lead with the viewer's own — "Self:" first.
      percents = find("#hero-secondary-percents", visible: :all).text
      assert percents.index("Self:") < percents.index("Mgr:"),
        "expected Self before Mgr in '#{percents}'"
    end
  end

  context "manager marks alignment complete" do
    setup { seed_alignment_started! }

    should "gate 'Mark alignment complete' behind full current-level alignment with a jump chip" do
      visit assessment_path(@report_assignment)
      assert_text "Aligning"
      # The one current-level cell has no agreed value yet — disabled
      # button plus the count chip pointing at the unaligned cell.
      assert_button "Mark alignment complete", disabled: true
      assert_selector "a", text: "1 to align"
    end

    should "hide the completion control on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@report_assignment)
      assert_text "Aligning"
      assert_no_button "Mark alignment complete", disabled: :all
      assert_no_selector "a", text: "1 to align"
    end

    should "enable completion once the last cell is agreed, then complete and freeze" do
      visit assessment_path(@report_assignment, capability: @cap_stable)
      assert_text "Aligning"
      wait_for_stimulus "matrix"
      assert_button "Mark alignment complete", disabled: true

      # Agreeing the final current-level cell enables the control in place
      # (Turbo Stream replace — no reload).
      click_rating_frequency("#rating-#{@cap_stable}-2", "Consistent")
      assert_button "Mark alignment complete", disabled: false
      assert_no_selector "a", text: "1 to align"

      auto_confirm do
        page.execute_script(<<~JS)
          const btn = Array.from(document.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Mark alignment complete");
          btn?.closest("form")?.requestSubmit(btn);
        JS
      end
      assert_text "Aligned"
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

  context "manager re-opens a completed alignment" do
    setup { seed_alignment_completed! }

    should "re-open a completed alignment back to Aligning, preserving agreed values" do
      visit assessment_path(@report_assignment)
      assert_text "Aligned"
      assert_button "Re-open alignment"

      auto_confirm do
        page.execute_script(<<~JS)
          const btn = Array.from(document.querySelectorAll("button"))
            .find(b => b.textContent.trim() === "Re-open alignment");
          btn?.closest("form")?.requestSubmit(btn);
        JS
      end

      assert_text "Aligning"
      assert_no_button "Re-open alignment"
      assert_button "Mark alignment complete"

      # The agreed value recorded before completion survives the re-open.
      ActsAsTenant.with_tenant(@tenant) do
        cell = AssessmentLevelRating.find_by(cycle_id: @cycle_id, person_id: @report.id,
          capability_stable_id: @cap_stable, level_ordinal: 2)
        assert_equal "consistent", cell.aligned_frequency
      end
    end

    # Both-viewport coverage of the button's responsive visibility: the desktop
    # case above asserts it is shown; this asserts it is hidden on mobile, where
    # re-open (like "Mark alignment complete") is intentionally unavailable.
    should "hide the Re-open alignment button on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessment_path(@report_assignment)
      assert_text "Aligned"
      assert_no_button "Re-open alignment"
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

  # Server-side seed: opens AND completes alignment (participant `aligned`).
  # Used by the re-open flow, which starts from a completed cycle.
  def seed_alignment_completed!
    ActsAsTenant.with_tenant(@tenant) do
      handler = PersonDevelopment::CommandHandler.new
      handler.start_alignment(@report.id, @framework_id, @cycle_id, started_by_id: @manager.id)
      handler.align_assessment(@report.id, @framework_id, @cap_stable,
        level_ordinal: 2, aligned_frequency: "consistent", cycle_id: @cycle_id,
        aligned_by_id: @manager.id)
      handler.complete_alignment(@report.id, @framework_id, @cycle_id, completed_by_id: @manager.id)
    end
  end
end

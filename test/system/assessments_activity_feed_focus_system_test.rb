# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsActivityFeedFocusSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze

  setup do
    page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)

    @tenant = FactoryBot.create(:tenant)
    @user = FactoryBot.create(:user, password: "password123")

    ActsAsTenant.with_tenant(@tenant) do
      @person = FactoryBot.create(:person, tenant: @tenant, email: @user.email, name: "Alice")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: @user, person: @person)

      handler = Frameworks::CommandHandler.new
      pd_handler = PersonDevelopment::CommandHandler.new
      @framework_id = SecureRandom.uuid_v7
      handler.create_framework(@framework_id, "Test FW")

      rf_id = SecureRandom.uuid_v7
      @role_id = SecureRandom.uuid_v7
      handler.add_role_family(@framework_id, rf_id, "Engineering")
      handler.add_role(@framework_id, @role_id, rf_id, "Engineer", "E", "ic")
      @level_id = SecureRandom.uuid_v7
      handler.add_level(@framework_id, @level_id, @role_id, 1, "Engineer 1", "E1", is_entry: true)

      @cat_id = SecureRandom.uuid_v7
      handler.add_capability_category(@framework_id, @cat_id, "Thinking", ordinal: 1)

      @cap1_id = SecureRandom.uuid_v7
      @cap1_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap1_id, @cap1_stable, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap1_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap1_id, 1, "Synthesises"
      )

      @cap2_id = SecureRandom.uuid_v7
      @cap2_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap2_id, @cap2_stable, @cat_id, "Problem Solving")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap2_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap2_id, 1, "Decomposes"
      )

      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      # Two ratings + two evidence items, half on cap1 / half on cap2.
      pd_handler.rate_self(@person.id, @framework_id, @cap1_stable,
        level_ordinal: 1, frequency: "consistent", cycle_id: @cycle_id)
      pd_handler.rate_self(@person.id, @framework_id, @cap2_stable,
        level_ordinal: 1, frequency: "occasional", cycle_id: @cycle_id)
      pd_handler.record_evidence(@person.id, @framework_id, SecureRandom.uuid_v7,
        capability_stable_id: @cap1_stable, level_ordinal: 1, source: "self",
        evidence_type: "project_outcome", content: "Cap1 evidence",
        title: "Cap1 launch", author_id: @person.id)
      pd_handler.record_evidence(@person.id, @framework_id, SecureRandom.uuid_v7,
        capability_stable_id: @cap2_stable, level_ordinal: 1, source: "self",
        evidence_type: "code_review", content: "Cap2 evidence",
        title: "Cap2 review", author_id: @person.id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  context "filter chips" do
    should "narrow the visible entries to ratings only when Ratings is selected" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_selector "[data-activity-feed-target='entry']", count: 4, visible: :all
      wait_for_stimulus "activity-feed"
      wait_for_turbo_idle

      click_filter_chip = <<~JS
        const chip = document.querySelector("[data-activity-feed-filter-param='ratings']");
        chip?.click();
      JS
      page.execute_script(click_filter_chip)

      # On starved CI, the click can race a Turbo Frame reconnect of the
      # activity-feed controller and miss the action handler. Retry once
      # if the data-hidden attributes haven't flipped yet.
      unless page.has_css?(
        "[data-kind-group='evidence'][data-hidden='true']", visible: :all, count: 2, wait: 4
      )
        wait_for_turbo_idle
        page.execute_script(click_filter_chip)
      end

      # Both evidence entries get data-hidden="true"; both rating entries
      # stay visible.
      assert_selector "[data-kind-group='evidence'][data-hidden='true']",
        visible: :all, count: 2
      assert_selector "[data-kind-group='ratings'][data-hidden='false']",
        visible: :all, count: 2
    end
  end

  context "focus highlight mode" do
    should "amber-accent the entries that match the focused capability" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane

      # Default mode is Filter; switch to Highlight for this test. Wait
      # for the activity-feed controller to connect first — without it
      # the click can land before the action handler is registered and
      # the mode never flips, flaking the assertions below.
      wait_for_stimulus "activity-feed"
      page.execute_script(<<~JS)
        document.querySelector("[data-activity-feed-mode-param='highlight']").click();
      JS

      # Focus cap1 by expanding its row.
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      # Cap1 entries get data-match="true"; cap2 entries do NOT.
      cap1_match_count = page.evaluate_script(<<~JS)
        document.querySelectorAll(
          "[data-capability-stable-id='#{@cap1_stable}'][data-match='true']"
        ).length
      JS
      cap2_match_count = page.evaluate_script(<<~JS)
        document.querySelectorAll(
          "[data-capability-stable-id='#{@cap2_stable}'][data-match='true']"
        ).length
      JS
      assert_operator cap1_match_count, :>, 0,
        "expected cap1 entries to be highlighted"
      assert_equal 0, cap2_match_count,
        "cap2 entries should NOT be highlighted when focus is cap1"

      # In Highlight mode, non-matching entries stay VISIBLE (just dim).
      cap2_hidden_count = page.evaluate_script(<<~JS)
        document.querySelectorAll(
          "[data-capability-stable-id='#{@cap2_stable}'][data-hidden='true']"
        ).length
      JS
      assert_equal 0, cap2_hidden_count,
        "Highlight mode keeps non-matching entries visible"
    end
  end

  context "focus filter mode" do
    should "hide non-matching entries when Filter mode is selected and focus is active" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane

      # No focus yet (the matrix dispatches category focus on connect,
      # but Filter mode of category-level focus shouldn't hide anything
      # since the category contains BOTH cap1 and cap2 here).
      page.execute_script(<<~JS)
        document.querySelector("[data-activity-feed-mode-param='filter']").click();
      JS

      # Now focus cap1 — Filter mode should hide cap2 entries.
      expand_matrix_row("#capability-name-#{@cap1_stable}")

      cap2_hidden_count = page.evaluate_script(<<~JS)
        document.querySelectorAll(
          "[data-capability-stable-id='#{@cap2_stable}'][data-hidden='true']"
        ).length
      JS
      assert_operator cap2_hidden_count, :>, 0,
        "cap2 entries should be hidden when Filter mode + cap1 focused"
    end
  end

  context "rating entry summary" do
    should "include the capability name so each entry is readable at a glance" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane

      assert_text "Self-rated Critical Thinking · L1"
      assert_text "Self-rated Problem Solving · L1"
    end
  end

  context "clear-focus banner" do
    should "surface a Show all activity link whenever focus is active and clear focus when clicked" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane

      # Initial connect dispatches category-level focus, so the banner
      # should be visible from page load.
      assert_selector "[data-activity-feed-target='focusBanner']", visible: true,
        text: "Show all activity"

      # Wait for any in-flight Turbo Frame fetches (e.g. the lazy activity
      # frame's initial load triggered by opening the pane) to settle.
      # Without this, a frame load that lands between clearFocus and the
      # assertion reconnects activity-feed and re-applies category focus,
      # re-showing the banner.
      wait_for_turbo_idle

      # Click "Show all activity" → focus clears, banner hides. Drive the
      # controller directly to avoid synthetic-click drops on CI.
      clear_focus_js = <<~JS
        const wrapper = document.querySelector("[data-controller~='activity-feed']");
        const ctrl = window.Stimulus
          .getControllerForElementAndIdentifier(wrapper, "activity-feed");
        ctrl?.clearFocus();
      JS
      page.execute_script(clear_focus_js)

      # A late Turbo Frame load can reconnect the activity-feed controller
      # and re-apply the initial category focus, re-showing the banner.
      # Re-issue clearFocus once if the banner is still visible after a
      # short wait — safe because focus only ever transitions one way here.
      unless page.has_no_css?("[data-activity-feed-target='focusBanner']:not(.hidden)", wait: 4)
        wait_for_turbo_idle
        page.execute_script(clear_focus_js)
      end

      assert page.has_no_css?(
        "[data-activity-feed-target='focusBanner']:not(.hidden)",
        wait: Capybara.default_max_wait_time
      ), "expected focus banner to hide after clearFocus"
    end
  end
end

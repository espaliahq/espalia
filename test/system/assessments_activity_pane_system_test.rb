# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsActivityPaneSystemTest < ApplicationSystemTestCase
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

      @cap_id = SecureRandom.uuid_v7
      @cap_stable = SecureRandom.uuid_v7
      handler.add_capability(@framework_id, @cap_id, @cap_stable, @cat_id, "Critical Thinking")
      handler.create_capability_role_binding(
        @framework_id, SecureRandom.uuid_v7, @cap_id, @role_id, weight: 1.0
      )
      handler.set_behavioural_expectation(
        @framework_id, SecureRandom.uuid_v7, SecureRandom.uuid_v7, @cap_id, 1, "Synthesises"
      )
      handler.publish_version(@framework_id, "test")

      level = FrameworkState::Level.find_by!(level_id: @level_id)
      pd_handler.assign_to_framework(@person.id, @framework_id, @role_id, level.level_id)

      cycle_handler = AssessmentCycles::CommandHandler.new
      @cycle_id = SecureRandom.uuid_v7
      cycle_handler.define_cycle(@cycle_id, @framework_id, "Q1", "regular", 1, defined_by: @person.id)
      cycle_handler.enroll(@cycle_id, @person.id, enrolled_by: @person.id)

      pd_handler.rate_self(@person.id, @framework_id, @cap_stable,
        level_ordinal: 1, frequency: "consistent", cycle_id: @cycle_id)

      @assignment = PersonFrameworkAssignment.for_person(@person.id).first
    end

    sign_in_as(@user)
  end

  context "activity pane" do
    should "default to closed and reveal the feed when toggled" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"

      # Default-closed: aside has the hidden class until the toggle fires.
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all

      page.execute_script(<<~JS)
        document.querySelector("[data-action*='activity-pane#toggle']").click();
      JS

      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_selector "#assessment-activity-pane", text: "Activity", visible: true
    end

    should "persist open state via cookie across navigations" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"

      page.execute_script(<<~JS)
        document.querySelector("[data-action*='activity-pane#toggle']").click();
      JS
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

      # Navigate away and back; pane should still be open.
      visit assessments_path
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
    end

    should "preserve activity feed scroll position across broadcast reloads" do
      # Pad the feed with enough evidence entries to make the pane scrollable.
      ActsAsTenant.with_tenant(@tenant) do
        pd_handler = PersonDevelopment::CommandHandler.new
        40.times do |i|
          pd_handler.record_evidence(@person.id, @framework_id, SecureRandom.uuid_v7,
            capability_stable_id: @cap_stable, level_ordinal: 1, source: "self",
            evidence_type: "project_outcome", title: "Entry #{i}",
            content: "Body content for entry #{i}.", author_id: @person.id)
        end
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"

      page.execute_script(<<~JS)
        document.querySelector("[data-action*='activity-pane#toggle']").click();
      JS
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_selector "#assessment-activity-pane turbo-frame#assessment-activity[complete]",
        visible: :all

      # Scroll the pane down and capture the resulting scrollTop.
      page.execute_script(<<~JS)
        const pane = document.getElementById("assessment-activity-pane");
        pane.scrollTop = 400;
      JS
      scrolled_to = page.evaluate_script(
        "document.getElementById('assessment-activity-pane').scrollTop"
      )
      assert scrolled_to.to_i > 0, "expected pane to be scrolled, got #{scrolled_to.inspect}"

      # Simulate a broadcast: replace the sync-signal element. The
      # MutationObserver in assessment_sync_controller treats this as the
      # cue to reload all three frames.
      page.execute_script(<<~JS)
        const parent = document.getElementById("assessment-sync-signal").parentElement;
        const replacement = document.createElement("div");
        replacement.id = "assessment-sync-signal";
        replacement.className = "hidden";
        replacement.dataset.assessmentSyncTarget = "signal";
        replacement.dataset.updatedAt = String(Date.now() / 1000);
        parent.replaceChild(replacement, document.getElementById("assessment-sync-signal"));
      JS

      # Wait for the activity frame to finish reloading.
      assert_selector "#assessment-activity-pane turbo-frame#assessment-activity[complete]",
        visible: :all

      # Scroll position should be restored to (close to) where we left it.
      restored = page.evaluate_script(
        "document.getElementById('assessment-activity-pane').scrollTop"
      )
      assert_equal scrolled_to.to_i, restored.to_i,
        "expected scrollTop preserved across broadcast reload; was #{scrolled_to}, now #{restored}"
    end
  end
end

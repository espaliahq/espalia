# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsActivityPaneSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze

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

  # Enough entries that the feed overflows any viewport the tests use.
  def record_many_evidence_entries(count = 40)
    ActsAsTenant.with_tenant(@tenant) do
      pd_handler = PersonDevelopment::CommandHandler.new
      count.times do |i|
        pd_handler.record_evidence(@person.id, @framework_id, SecureRandom.uuid_v7,
          capability_stable_id: @cap_stable, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", title: "Entry #{i}",
          content: "Body content for entry #{i}.", author_id: @person.id, valence: "demonstrated")
      end
    end
  end

  def open_loaded_activity_pane
    visit assessment_path(@assignment)
    wait_for_stimulus "activity-pane"
    toggle_activity_pane
    assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
    assert_selector "#assessment-activity-pane turbo-frame#assessment-activity[complete]",
      visible: :all
  end

  def pane_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const pane = document.getElementById("assessment-activity-pane").getBoundingClientRect();
        return { top: pane.top, bottom: pane.bottom, viewport: window.innerHeight };
      })()
    JS
  end

  # The header shrinks as the hero collapses and the sticky offset follows
  # it through a ResizeObserver, so the geometry settles a frame or two late.
  def assert_pane_within_viewport
    geometry = nil
    within_viewport = wait_until_js do
      geometry = pane_geometry
      geometry["bottom"] <= geometry["viewport"] + 0.5
    end
    assert within_viewport,
      "expected the pane's bottom (#{geometry['bottom']}) within the viewport (#{geometry['viewport']})"
  end

  # Scrolls the pane to its end and checks the last entry is on screen,
  # inside the pane and inside the viewport.
  def assert_last_entry_reachable
    page.execute_script(<<~JS)
      const pane = document.getElementById("assessment-activity-pane");
      pane.scrollTop = pane.scrollHeight;
    JS
    reachable = wait_until_js do
      page.evaluate_script(<<~JS)
        (() => {
          const pane = document.getElementById("assessment-activity-pane");
          const entries = pane.querySelectorAll("ul > li");
          const last = entries[entries.length - 1].getBoundingClientRect();
          const box = pane.getBoundingClientRect();
          return entries.length > 1 && last.bottom <= box.bottom + 0.5 &&
            last.bottom <= window.innerHeight + 0.5 && last.top >= box.top;
        })()
      JS
    end
    assert reachable, "expected the feed's last entry to scroll into view inside the pane"
  end

  def wait_until_js(seconds: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      result = yield
      return result if result
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
    nil
  end

  context "activity pane" do
    should "default to closed and reveal the feed when toggled" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"

      # Default-closed: aside has the hidden class until the toggle fires.
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all

      toggle_activity_pane

      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_selector "#assessment-activity-pane", text: "Activity", visible: true
    end

    should "name the author on an evidence-recorded feed entry" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(
          @person.id, @framework_id, SecureRandom.uuid_v7,
          capability_stable_id: @cap_stable, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", title: "Launch",
          content: "Shipped the thing.", author_id: @person.id, valence: "demonstrated"
        )
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_selector "#assessment-activity-pane turbo-frame#assessment-activity[complete]",
        visible: :all

      assert_selector "#assessment-activity-pane", text: "Alice recorded “Launch”", visible: true
    end

    should "persist open state via cookie across navigations" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"

      toggle_activity_pane
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
            content: "Body content for entry #{i}.", author_id: @person.id, valence: "demonstrated")
        end
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"

      toggle_activity_pane
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

    should "keep the pane's bottom on screen with the hero expanded and collapsed" do
      record_many_evidence_entries
      open_loaded_activity_pane

      assert_operator page.evaluate_script("window.scrollY"), :<, 1
      assert_pane_within_viewport
      assert_last_entry_reachable

      # Past the hero's 240px collapse range; the scroll root's min-height
      # floor guarantees the page can scroll this far.
      page.execute_script("document.getElementById('assessment-activity-pane').scrollTop = 0")
      page.execute_script("window.scrollTo(0, 360)")
      assert_operator page.evaluate_script("window.scrollY"), :>=, 300
      assert_pane_within_viewport
      assert_last_entry_reachable
    end

    should "keep the end of the feed from scrolling the page" do
      open_loaded_activity_pane

      assert_equal "contain",
        page.evaluate_script(
          "getComputedStyle(document.getElementById('assessment-activity-pane')).overscrollBehaviorY"
        )
    end

    should "push ?activity=open to the URL on toggle" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"

      assert_no_match(/[?&]activity=/, page.current_url)

      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_match(/[?&]activity=open/, page.current_url)

      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
      assert_match(/[?&]activity=closed/, page.current_url)

      # Back-button restoration is exercised at unit-level by the popstate
      # listener in activity_pane_controller; Turbo Drive's behaviour on
      # query-string-only history changes is too racy to assert reliably
      # in a system test without papering over real flakes.
    end

    should "honour ?activity=open in the URL even when the cookie says closed" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all

      visit "#{assessment_path(@assignment)}?activity=open"
      wait_for_stimulus "activity-pane"
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
    end
  end

  context "activity pane on mobile" do
    setup do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
    end

    should "open the overlay full height with its last entry reachable" do
      record_many_evidence_entries
      open_loaded_activity_pane

      geometry = pane_geometry
      assert_in_delta 0, geometry["top"], 0.5,
        "expected the overlay to start at the top of the viewport, got #{geometry['top']}"
      assert_pane_within_viewport
      assert_last_entry_reachable
    end

    should "close on outside click but stay open when click lands inside the pane" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"

      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

      # Clicking inside the pane keeps it open.
      page.execute_script(<<~JS)
        document.getElementById("assessment-activity-pane").dispatchEvent(
          new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
        )
      JS
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

      # Clicking outside (on <main>) closes the pane.
      page.execute_script(<<~JS)
        document.querySelector("main").dispatchEvent(
          new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
        )
      JS
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
    end

    should "name the author on an evidence-recorded feed entry" do
      ActsAsTenant.with_tenant(@tenant) do
        PersonDevelopment::CommandHandler.new.record_evidence(
          @person.id, @framework_id, SecureRandom.uuid_v7,
          capability_stable_id: @cap_stable, level_ordinal: 1, source: "self",
          evidence_type: "project_outcome", title: "Launch",
          content: "Shipped the thing.", author_id: @person.id, valence: "demonstrated"
        )
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_selector "#assessment-activity-pane turbo-frame#assessment-activity[complete]",
        visible: :all

      assert_selector "#assessment-activity-pane", text: "Alice recorded “Launch”", visible: true
    end
  end
end

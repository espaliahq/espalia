# frozen_string_literal: true

require "application_system_test_case"

class AssessmentsActivityPaneSystemTest < ApplicationSystemTestCase
  DESKTOP_SIZE = [ 1400, 1400 ].freeze
  MOBILE_SIZE  = [ 375, 812 ].freeze
  TOGGLE = "button[aria-controls='assessment-activity-pane']"

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

  # Marks the entry the page settles on once the matrix's first load has
  # written its own, so a test can tell which entry Back or a close lands on.
  def mark_history_entry
    visit assessment_path(@assignment)
    wait_for_stimulus "activity-pane"
    assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all
    page.execute_script("history.replaceState({ ...history.state, probe: true }, '')")
  end

  # Turbo stamps its own state on an entry it pops back to, wiping the probe,
  # so the pane's marker gone shows its entry was left. The entry it opened on
  # says closed, or the cookie would reopen the pane there on a reload.
  # (Counting entries can't: Chrome caps history.length at 50 per tab.)
  def assert_back_on_opening_entry
    assert_nil page.evaluate_script("history.state?.sidePanelOverlay ?? null")
    assert_current_path assessment_path(@assignment, activity: "closed")
  end

  # Closing must step Back off the overlay's entry. Rewriting that entry in
  # place would also end on a closed URL with no marker, but leave it in history.
  def close_overlay_by_its_button
    assert_selector "#assessment-activity-pane button[aria-label='Close activity']", visible: true
    expect_a_back
    page.execute_script(<<~JS)
      window.overlayPopped = false
      window.addEventListener("popstate", () => { window.overlayPopped = true }, { once: true })
      document.querySelector("#assessment-activity-pane button[aria-label='Close activity']").click()
    JS
    assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
    assert wait_until_js { page.evaluate_script("window.overlayPopped") }, "closing stepped Back off the overlay's entry"
    assert_back_landed
    assert_back_on_opening_entry
    assert page.evaluate_script("document.activeElement.matches(arguments[0])", TOGGLE),
      "closing left focus behind instead of on the toggle"
  end

  # Both entries carry the same path, so the URL alone can't show a Back has
  # landed; a second Back sent too soon leaves the page behind as well. Turbo
  # starts its restore visit inside its own popstate listener, before ours, so
  # a Back that starts one lands only at that visit's turbo:load. A Back that
  # leaves for another document drops the flag, which counts as landed.
  def go_back_and_wait_until_landed
    expect_a_back
    page.go_back
    assert_back_landed
  end

  def expect_a_back
    page.execute_script(<<~JS)
      window.backLanded = false
      let restoring = false
      const settle = () => { window.backLanded = true }
      document.addEventListener("turbo:visit", () => { restoring = true }, { once: true })
      window.addEventListener("popstate", () => {
        if (restoring) document.addEventListener("turbo:load", settle, { once: true })
        else settle()
      }, { once: true })
    JS
  end

  def assert_back_landed
    assert wait_until_js { page.evaluate_script("window.backLanded !== false") }, "Back never landed"
  end

  # The matrix may push an entry over the overlay's as its frame loads (#433),
  # so the overlay can take a second Back to close. Without an overlay entry
  # of its own, those Backs leave the assessment instead.
  def back_until_pane_closes
    2.times do
      break if page.has_css?("#assessment-activity-pane[data-pane-state='closed']", visible: :all, wait: 0)

      go_back_and_wait_until_landed
    end
    assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
  end

  # A slow runner reloads the restored matrix frame, and its load pushes an
  # entry over the overlay's (#433). Holding that load keeps the test on the
  # pane's own entry; drop this once #433 is fixed.
  def hold_matrix_frame_loads
    page.execute_script(<<~JS)
      document.addEventListener("turbo:before-fetch-request", (event) => {
        if (event.target.id === "assessment-matrix") event.preventDefault()
      })
    JS
  end

  # Chrome keeps 50 history entries per tab, and the suite shares one tab, so a
  # late test starts at the cap. A capped tab dropped the entries under a
  # restored overlay, and closing it went Back past the assessment.
  def in_a_fresh_tab
    tab = open_new_window(:tab)
    within_window(tab) do
      keep_page_focused
      yield
    end
  ensure
    tab&.close
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
          if (entries.length < 2) return false;
          const last = entries[entries.length - 1].getBoundingClientRect();
          const box = pane.getBoundingClientRect();
          return last.bottom <= box.bottom + 0.5 &&
            last.bottom <= window.innerHeight + 0.5 && last.top >= box.top;
        })()
      JS
    end
    assert reachable, "expected the feed's last entry to scroll into view inside the pane"
  end

  # Re-signs in as Alice's manager, so the same URL renders ManagerShowView.
  def sign_in_as_manager
    manager_user = FactoryBot.create(:user, password: "password123")
    ActsAsTenant.with_tenant(@tenant) do
      manager = FactoryBot.create(:person, tenant: @tenant, email: manager_user.email, name: "Manager Mia")
      FactoryBot.create(:tenant_user, tenant: @tenant, user: manager_user, person: manager)
      @person.update!(manager: manager)
    end
    Capybara.reset_sessions!
    sign_in_as(manager_user)
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

    should "stay open under a click inside a modal laid over it, and close once the modal has gone" do
      open_loaded_activity_pane
      click_outside = <<~JS
        document.querySelector(arguments[0]).dispatchEvent(
          new MouseEvent("click", { bubbles: true, cancelable: true, view: window })
        )
      JS
      page.execute_script(<<~JS)
        const overlay = document.createElement("div")
        overlay.id = "probe-modal"
        overlay.dataset.modalTarget = "overlay"
        document.body.append(overlay)
      JS

      page.execute_script(click_outside, "#probe-modal")
      assert page.evaluate_script("document.querySelector('#assessment-activity-pane').dataset.paneState === 'open'"),
        "a click inside the modal closed the pane under it"

      page.execute_script("document.getElementById('probe-modal').remove()")
      page.execute_script(click_outside, "main")
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

  context "the activity pane and the Back button" do
    should "add no history entry beside the matrix, so Back still leaves the entry it was opened on" do
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all

      assert page.evaluate_script("history.state?.probe === true"), "the pane wrote over the entry it opened on, not a new one"
    end

    # The matrix pushes one same-URL entry when its frame first loads (#433),
    # so the page may take two Backs to leave; toggles must add none on top.
    should "leave the page on Back after the pane is opened and closed beside the matrix" do
      visit assessments_path
      assert_text "My Assessments"
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all

      2.times do
        break unless page.current_path == assessment_path(@assignment)

        go_back_and_wait_until_landed
      end
      assert_current_path assessments_path
      assert_text "My Assessments"
    end

    should "close the overlay on Back, returning to the entry it was opened on" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_match(/[?&]activity=open/, page.current_url)

      page.go_back
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
      assert_back_on_opening_entry
    end

    should "close the overlay on Back when the pane was opened beside the matrix and the window then narrowed" do
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      assert wait_until_js { page.evaluate_script("history.state?.sidePanelOverlay != null") },
        "narrowing gave the overlay no entry of its own"
      assert_match(/[?&]activity=open/, page.current_url)

      page.go_back
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
      assert_back_on_opening_entry
    end

    should "keep the pane open and leave the page on Back when the overlay was opened and the window then widened" do
      visit assessments_path
      assert_text "My Assessments"
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      assert wait_until_js { page.evaluate_script("history.state?.sidePanelOverlay == null") },
        "widening left the overlay's entry in history"
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_match(/[?&]activity=open/, page.current_url)

      2.times do
        break unless page.current_path == assessment_path(@assignment)

        go_back_and_wait_until_landed
      end
      assert_current_path assessments_path
      assert_text "My Assessments"
    end

    should "step back off the overlay's entry when Forward returns to it after the window widened" do
      visit assessments_path
      assert_text "My Assessments"
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      hold_matrix_frame_loads
      page.driver.browser.manage.window.resize_to(*DESKTOP_SIZE)
      assert wait_until_js { page.evaluate_script("history.state?.sidePanelOverlay == null") },
        "widening left the overlay's entry in history"

      page.execute_script(<<~JS)
        window.pops = 0
        window.addEventListener("popstate", () => { window.pops += 1 })
      JS
      page.go_forward
      assert wait_until_js { page.evaluate_script("window.pops >= 2 && history.state?.sidePanelOverlay == null") },
        "Forward left the page on the overlay's entry beside the matrix"
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_match(/[?&]activity=open/, page.current_url)

      2.times do
        break unless page.current_path == assessment_path(@assignment)

        go_back_and_wait_until_landed
      end
      assert_current_path assessments_path
    end

    should "close the overlay on Back when the page opens with it up from the URL" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      in_a_fresh_tab do
        visit assessments_path
        assert_text "My Assessments"
        visit assessment_path(@assignment, activity: "open")
        wait_for_stimulus "activity-pane"
        assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

        back_until_pane_closes
        assert_back_on_opening_entry
      end
    end

    should "close the overlay on Back when the page opens with it up from the cookie" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      visit assessments_path
      assert_text "My Assessments"
      page.driver.browser.manage.add_cookie(name: "assessment_activity_pane_open", value: "open")
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

      back_until_pane_closes
      assert_back_on_opening_entry
    end

    should "take the overlay's history entry back when its close button shuts it" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      close_overlay_by_its_button
    end

    should "take the overlay's history entry back when its close button shuts it after Back and Forward" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      hold_matrix_frame_loads

      go_back_and_wait_until_landed
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
      page.go_forward
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert wait_until_js { page.evaluate_script("history.state?.sidePanelOverlay === 'activity'") },
        "Forward left the overlay's entry without its marker"
      assert wait_until_js { page.evaluate_script("document.querySelector('#assessment-activity-pane').contains(document.activeElement)") },
        "Forward reopened the overlay with focus left behind it"

      close_overlay_by_its_button
    end

    # Back and Forward are Turbo restoration visits, and their render drops focus.
    should "keep focus on the toggle through Back and in the overlay through Forward" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      mark_history_entry
      toggle_activity_pane
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      hold_matrix_frame_loads
      focus_on_toggle = "document.activeElement.matches(#{TOGGLE.to_json})"
      focus_in_pane = "document.querySelector('#assessment-activity-pane').contains(document.activeElement)"

      2.times do
        go_back_and_wait_until_landed
        assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
        assert wait_until_js { page.evaluate_script(focus_on_toggle) }, "Back closed the overlay with focus lost"
        page.go_forward
        assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
        assert wait_until_js { page.evaluate_script(focus_in_pane) }, "Forward reopened the overlay with focus lost"
      end
    end

    # Turbo restores a page only from an entry that carries its own state; the
    # overlay's entry didn't, so Back left the other page on screen under this URL.
    should "bring the assessment back when Back returns from another page to the open overlay" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      in_a_fresh_tab do
        mark_history_entry
        toggle_activity_pane
        assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

        page.execute_script("Turbo.visit(arguments[0])", assessments_path)
        assert_no_selector "#assessment-activity-pane", visible: :all

        hold_matrix_frame_loads
        page.go_back
        assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
        assert_selector "turbo-frame#assessment-matrix", visible: :all
        assert_match(/[?&]activity=open/, page.current_url)

        wait_for_stimulus "activity-pane"
        close_overlay_by_its_button
      end
    end
  end

  context "the overlay and the keyboard" do
    setup { page.driver.browser.manage.window.resize_to(*MOBILE_SIZE) }

    should "take focus in when it opens, and close on Escape with focus back on its toggle" do
      mark_history_entry
      hold_matrix_frame_loads
      page.execute_script("document.querySelector(arguments[0]).click()", TOGGLE)
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      assert_equal "assessment-activity-pane", page.evaluate_script("document.activeElement.id")

      expect_a_back
      press_escape
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
      assert_back_landed
      assert page.evaluate_script("document.activeElement.matches(arguments[0])", TOGGLE), "focus returns to the toggle"
    end

    should "leave Escape to a modal open over it" do
      open_loaded_activity_pane
      page.execute_script(<<~JS)
        const overlay = document.createElement("div")
        overlay.dataset.modalTarget = "overlay"
        document.body.append(overlay)
      JS

      press_escape
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
    end

    # The menu's own Escape closes it before a bubbling listener would look,
    # so the pane checks in the capture phase, while the menu is still open.
    should "leave the first Escape to a menu open inside it, and close on the next" do
      open_loaded_activity_pane
      page.execute_script(<<~JS)
        document.getElementById("assessment-activity-pane").insertAdjacentHTML("afterbegin", `
          <div id="probe-dropdown" data-controller="dropdown" data-action="keydown.esc@window->dropdown#close">
            <button type="button" data-action="dropdown#toggle" data-dropdown-target="trigger">More</button>
            <div role="menu" data-dropdown-target="menu" hidden><button role="menuitem">Item</button></div>
          </div>`)
      JS
      wait_for_stimulus "dropdown", scope: "#probe-dropdown"
      # Reconnect the pane so the menu's listener comes first, as the navbar's
      # menus do on a real page: Stimulus runs a shared window listener's
      # bindings in the order they connected.
      page.execute_script(<<~JS)
        const host = document.getElementById("assessment-activity-pane").closest("[data-controller~='activity-pane']")
        host.removeAttribute("data-connected")
        host.dataset.controller = ""
        requestAnimationFrame(() => { host.dataset.controller = "activity-pane" })
      JS
      wait_for_stimulus "activity-pane"
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
      page.execute_script("document.querySelector('#probe-dropdown button').click()")
      assert_selector "#probe-dropdown [role='menu']", visible: true

      # From the pane, as a real key would come: a dispatch on window itself
      # runs its listeners in the order they were added, capture or not.
      press_escape(scope: "#probe-dropdown")
      assert_no_selector "#probe-dropdown [role='menu']", visible: true
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true

      press_escape(scope: "#assessment-activity-pane")
      assert_selector "#assessment-activity-pane[data-pane-state='closed']", visible: :all
    end
  end

  context "the activity pane beside the matrix and Escape" do
    should "stay open on Escape" do
      open_loaded_activity_pane
      press_escape
      assert_selector "#assessment-activity-pane[data-pane-state='open']", visible: true
    end
  end

  context "activity pane in the manager view" do
    setup do
      record_many_evidence_entries
      sign_in_as_manager
    end

    should "keep the pane's bottom on screen and its last entry reachable on desktop" do
      open_loaded_activity_pane
      assert_selector "h1", text: "Alice"

      assert_pane_within_viewport
      assert_last_entry_reachable

      page.execute_script("document.getElementById('assessment-activity-pane').scrollTop = 0")
      page.execute_script("window.scrollTo(0, 360)")
      assert_operator page.evaluate_script("window.scrollY"), :>=, 300
      assert_pane_within_viewport
      assert_last_entry_reachable
    end

    should "open the overlay full height with its last entry reachable on mobile" do
      page.driver.browser.manage.window.resize_to(*MOBILE_SIZE)
      open_loaded_activity_pane
      assert_selector "h1", text: "Alice"

      assert_in_delta 0, pane_geometry["top"], 0.5
      assert_pane_within_viewport
      assert_last_entry_reachable
    end
  end
end

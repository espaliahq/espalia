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

  # Polls a JS predicate (Capybara's `assert_selector` only retries on
  # CSS selectors, not on values read via execute_script). Used by the
  # scroll-driven assertions below where the predicate is "the sidebar
  # has finished scrolling" or "the picker has settled on this card"
  # — both are race conditions on CI that need polling, not snapshots.
  def wait_until_js(seconds: Capybara.default_max_wait_time, &block)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    loop do
      result = yield
      return result if result
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
    nil
  end

  # Click on a capability card's header sets capability-level focus.
  # Drive it via Stimulus directly (not Capybara click) for two reasons:
  # the card header has no role/accessible name (it's a focus affordance,
  # not a button), and synthetic clicks against non-interactive elements
  # have been observed to drop on slow CI. Direct controller invocation
  # is the same path the click event would resolve to via Stimulus.
  def click_card_header(stable_id)
    page.execute_script(<<~JS)
      const matrix = document.querySelector("[data-controller~='matrix']");
      const ctrl = window.Stimulus.getControllerForElementAndIdentifier(matrix, "matrix");
      const card = document.querySelector(
        "[data-matrix-target='card'][data-capability-stable-id='#{stable_id}']"
      );
      const target = card?.querySelector("[data-action*='matrix#focusCapability']");
      ctrl?.focusCapability({
        currentTarget: target, target: target, stopPropagation: () => {}
      });
    JS
  end

  context "focus highlight mode" do
    should "narrow data-match to the focused capability when its card header is clicked" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane
      wait_for_stimulus "activity-feed"
      wait_for_stimulus "matrix"
      wait_for_turbo_idle

      click_card_header(@cap1_stable)

      # Two cap1 entries (one rating, one evidence) should match; two
      # cap2 entries should not.
      assert_selector "[data-capability-stable-id='#{@cap1_stable}'][data-match='true']",
        visible: :all, count: 2
      assert_selector "[data-capability-stable-id='#{@cap2_stable}'][data-match='false']",
        visible: :all, count: 2
    end
  end

  context "focus filter mode" do
    should "hide non-matching entries when Filter mode is selected and focus is active" do
      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane
      wait_for_stimulus "activity-feed"
      wait_for_stimulus "matrix"
      wait_for_turbo_idle

      # Default mode is "filter" (the cookie default). Click cap2's card
      # header — non-matching cap1 entries should hide entirely.
      click_card_header(@cap2_stable)

      assert_selector "[data-capability-stable-id='#{@cap1_stable}'][data-hidden='true']",
        visible: :all, count: 2
      assert_selector "[data-capability-stable-id='#{@cap2_stable}'][data-hidden='false']",
        visible: :all, count: 2
    end
  end

  # Scroll the page so the named card occupies the majority of the
  # content band (the viewport area below the sticky chrome). After
  # this, the area-based picker in `matrix#updateFocusedCapabilityFromScroll`
  # should pick the named card as focused.
  #
  # Programmatic scrollTo in headless Chrome doesn't reliably emit a
  # scroll event, so set the user-scroll flag on the controller
  # directly — real users always trip it on their first scroll.
  #
  # Two-pass scroll: pass 1 triggers the CSS scroll-driven hero collapse
  # (which shrinks the doc height by ~120px). A single pass that
  # computes from pre-collapse layout misses by exactly that delta.
  # Pass 2 re-measures post-collapse and lands the target.
  def scroll_card_into_band(stable_id, offset_below_chrome: 8)
    page.execute_script(<<~JS)
      const matrix = document.querySelector("[data-controller~='matrix']");
      const ctrl = window.Stimulus.getControllerForElementAndIdentifier(matrix, "matrix");
      if (ctrl) ctrl._sawUserScroll = true;
      window.scrollTo({ top: 500, behavior: "instant" });
    JS
    # First scroll triggers the CSS scroll-driven hero collapse which
    # rewrites doc height by ~120px. CI's headless Chrome is slower at
    # settling layout than dev machines; give it real headroom before
    # measuring positions for the second scroll.
    sleep 0.5
    page.execute_script(<<~JS)
      // Force layout flush before measuring so the second scroll uses
      // post-collapse positions, not pre-collapse cached rects.
      void document.body.offsetHeight;
      const card = document.querySelector(
        "[data-matrix-target='card'][data-capability-stable-id='#{stable_id}']"
      );
      const stickyH = parseFloat(
        getComputedStyle(document.documentElement)
          .getPropertyValue("--sticky-header-h")
      ) || 0;
      const targetDocTop =
        card.getBoundingClientRect().top + window.scrollY - stickyH - #{offset_below_chrome};
      window.scrollTo({ top: targetDocTop, behavior: "instant" });
    JS
    # Let the final layout settle, then dispatch a synthetic scroll
    # event so the picker fires once more against the SETTLED state.
    # Without this, on slow CI runners the picker can fire against an
    # intermediate frame mid-second-scroll and never re-fire (no more
    # scroll events to trigger it) — leaving focus on the wrong card.
    sleep 0.5
    page.execute_script(<<~JS)
      void document.body.offsetHeight;
      window.dispatchEvent(new Event("scroll"));
    JS
  end

  context "highlight mode scrolls first match into view" do
    should "scroll the sidebar to the first highlighted entry when focus changes" do
      # Add many cap1 entries before any cap2 entries so the cap2-only
      # entries (the post-focus match targets) are below the fold.
      ActsAsTenant.with_tenant(@tenant) do
        15.times do |i|
          PersonDevelopment::CommandHandler.new.record_evidence(
            @person.id, @framework_id, SecureRandom.uuid_v7,
            capability_stable_id: @cap1_stable, level_ordinal: 1,
            source: "self", evidence_type: "project_outcome",
            content: "Filler #{i}", title: "Filler #{i}",
            author_id: @person.id
          )
        end
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane
      wait_for_stimulus "activity-feed"
      wait_for_stimulus "matrix"
      wait_for_turbo_idle

      # Switch to highlight mode so the rest of the feed stays visible
      # and the matching entry has to be scrolled into view (filter mode
      # would hide everything else and obviate the scroll).
      page.execute_script(<<~JS)
        const wrapper = document.querySelector("[data-controller~='activity-feed']");
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(wrapper, "activity-feed");
        ctrl.setMode({ params: { mode: "highlight" } });
      JS

      # Click cap2's card header → cap2 entries become the matches; the
      # sidebar should scroll them into view since they're the only
      # cap2 entries below ~16 cap1 entries.
      click_card_header(@cap2_stable)

      # Poll for #scrollFirstMatchIntoView's smooth scroll to settle —
      # snapshot reads land mid-animation on slow CI and report
      # entry.top still below the aside's visible bottom.
      diag = wait_until_js do
        result = page.execute_script(<<~JS)
          const aside = document.getElementById("assessment-activity-pane");
          const entry = aside.querySelector(
            "[data-activity-feed-target='entry'][data-capability-stable-id='#{@cap2_stable}'][data-match='true']"
          );
          if (!entry) return JSON.stringify({ entryFound: false });
          const asideRect = aside.getBoundingClientRect();
          const entryRect = entry.getBoundingClientRect();
          return JSON.stringify({
            entryFound: true,
            inView: entryRect.top >= asideRect.top && entryRect.bottom <= asideRect.bottom,
            entryTop: entryRect.top,
            asideTop: asideRect.top,
            asideBottom: asideRect.bottom
          });
        JS
        parsed = JSON.parse(result)
        parsed if parsed["entryFound"] && parsed["inView"]
      end
      assert diag,
        "expected the first matching entry to scroll into the sidebar viewport within the wait window"
    end
  end

  context "highlight mode: cell focus from chip click" do
    should "scroll the sidebar to the first highlighted entry when a chip sets cell focus" do
      ActsAsTenant.with_tenant(@tenant) do
        15.times do |i|
          PersonDevelopment::CommandHandler.new.record_evidence(
            @person.id, @framework_id, SecureRandom.uuid_v7,
            capability_stable_id: @cap1_stable, level_ordinal: 1,
            source: "self", evidence_type: "project_outcome",
            content: "Filler #{i}", title: "Filler #{i}",
            author_id: @person.id
          )
        end
      end

      visit assessment_path(@assignment)
      wait_for_stimulus "activity-pane"
      toggle_activity_pane
      wait_for_stimulus "activity-feed"
      wait_for_stimulus "matrix"
      wait_for_turbo_idle

      page.execute_script(<<~JS)
        const wrapper = document.querySelector("[data-controller~='activity-feed']");
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(wrapper, "activity-feed");
        ctrl.setMode({ params: { mode: "highlight" } });
      JS

      # Click cap2's L1 chip — sets cell focus, sidebar should scroll
      # to the matching cap2 + L1 entry.
      page.execute_script(<<~JS)
        const matrix = document.querySelector("[data-controller~='matrix']");
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(matrix, "matrix");
        const chip = document.getElementById("cell-#{@cap2_stable}-1");
        ctrl?.focusChip({ currentTarget: chip, target: chip, stopPropagation: () => {} });
      JS

      diag = wait_until_js do
        result = page.execute_script(<<~JS)
          const aside = document.getElementById("assessment-activity-pane");
          const entry = aside.querySelector(
            "[data-activity-feed-target='entry'][data-capability-stable-id='#{@cap2_stable}'][data-match='true']"
          );
          if (!entry) return JSON.stringify({ entryFound: false });
          const asideRect = aside.getBoundingClientRect();
          const entryRect = entry.getBoundingClientRect();
          return JSON.stringify({
            entryFound: true,
            inView: entryRect.top >= asideRect.top && entryRect.bottom <= asideRect.bottom,
            entryTop: entryRect.top,
            asideTop: asideRect.top,
            asideBottom: asideRect.bottom
          });
        JS
        parsed = JSON.parse(result)
        parsed if parsed["entryFound"] && parsed["inView"]
      end
      assert diag,
        "expected the first matching entry to scroll into the sidebar viewport within the wait window"
    end
  end

  context "scroll-driven capability focus" do
    should "track the card with the most visible area in the content band as the user scrolls down" do
      page.driver.browser.manage.window.resize_to(900, 600)

      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      # Frame must be complete before scrolling — `#syncFrameUrlToBrowser`
      # races otherwise and can clobber state mid-test.
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

      scroll_card_into_band(@cap2_stable)

      # IntersectionObserver fires async; the focus update is scheduled
      # via requestAnimationFrame. Wait for the data-focused attribute
      # to land on cap2.
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='true']"
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap1_stable}'][data-focused='false']"
    end

    should "switch focus symmetrically when scrolling back up — area-based, not threshold-based" do
      page.driver.browser.manage.window.resize_to(900, 600)

      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

      # First scroll all the way down to cap2 — establishes cap2 focus.
      scroll_card_into_band(@cap2_stable)
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='true']"

      # Now scroll back up to a position where cap1 covers most of the
      # band — area-based picker should switch BACK to cap1. The previous
      # threshold-based rule would keep cap2 focused until its top
      # crossed back above the sticky-chrome line, leaving focus stuck
      # on a card whose visual share of the screen had already shrunk.
      scroll_card_into_band(@cap1_stable)

      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap1_stable}'][data-focused='true']"
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='false']"
    end
  end

  context "cell focus downgrades to capability focus once the user scrolls past the focused card" do
    should "preserve cell focus while the card is still the area winner, and hand off when another card overtakes it" do
      page.driver.browser.manage.window.resize_to(900, 600)

      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      # Click cap1's L1 chip — sets cell focus on (cap1, L1).
      page.execute_script(<<~JS)
        const matrix = document.querySelector("[data-controller~='matrix']");
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(matrix, "matrix");
        const chip = document.getElementById("cell-#{@cap1_stable}-1");
        ctrl?.focusChip({ currentTarget: chip, target: chip, stopPropagation: () => {} });
      JS
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap1_stable}'][data-focused='true']"

      # The chip click arms the scroll-observer suppression for 1800ms
      # so the scroll-to-card animation isn't overwritten mid-flight.
      # In a real session the user spends well past that on the focused
      # cell before scrolling; the test waits past it before simulating
      # the next scroll so the picker is allowed to fire.
      sleep 2.0

      # Scroll past cap1 so cap2 is now the area winner. Cell focus on
      # cap1 should downgrade to capability focus on cap2 — the sidebar
      # re-narrows to whatever the user is now reading.
      scroll_card_into_band(@cap2_stable)

      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='true']"
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap1_stable}'][data-focused='false']"
    end
  end

  context "category chip click" do
    should "keep category focus active even after the programmatic scroll lands" do
      page.driver.browser.manage.window.resize_to(900, 600)
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      wait_for_stimulus "category-nav"

      # Dispatch category-level focus via category_nav (as a chip click
      # would). The trigger fires `matrix:focus-changed` and a smooth
      # scroll. Without the matrix_controller picking up the external
      # focus + suppressing its own scroll observer, the IntersectionObserver
      # would immediately overwrite category focus with capability focus
      # on whichever card lands in the viewport first.
      # Synchronously: dispatch the chip click AND read currentFocus
      # within a single execute_script. The listener fires synchronously
      # when the dispatch happens, so by the time the next line of the
      # script runs, currentFocus must already be category. This sidesteps
      # ALL async timing — if the assertion fails here, it's a real
      # regression in the listener's same-tick behaviour, not a race.
      level = page.execute_script(<<~JS)
        const navEl = document.querySelector("[data-controller~='category-nav']");
        const ctrl = window.Stimulus.getControllerForElementAndIdentifier(navEl, "category-nav");
        const chip = navEl.querySelector("nav#category-tabs a[data-category-id='#{@cat_id}']");
        ctrl?.scrollTo({
          preventDefault: () => {},
          currentTarget: chip
        });
        const matrixEl = document.querySelector("[data-controller~='matrix']");
        const matrixCtrl = window.Stimulus.getControllerForElementAndIdentifier(matrixEl, "matrix");
        if (matrixCtrl) matrixCtrl._sawUserScroll = true;
        return matrixCtrl?.currentFocus?.level;
      JS
      assert_equal "category", level
      # And no card should carry the capability-focus ring.
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap1_stable}'][data-focused='false']"
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='false']"
    end
  end

  context "capability focus persistence" do
    should "preserve the focused capability across a full page reload" do
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      # Click cap2's card header → capability focus on cap2 → URL must
      # carry ?capability=cap2_stable so a reload restores it.
      click_card_header(@cap2_stable)
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='true']"

      url_before = page.current_url
      assert_match(/capability=#{Regexp.escape(@cap2_stable)}/, url_before,
        "expected ?capability= in URL after capability click")

      # Full page reload — visit the URL again.
      visit url_before
      wait_for_stimulus "matrix"

      # cap2's card should reload focused, cap1's should not.
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='true']"
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap1_stable}'][data-focused='false']"
    end
  end

  context "scroll-driven URL sync" do
    should "update ?capability= as the user scrolls so reload restores the scroll-focused card" do
      page.driver.browser.manage.window.resize_to(900, 600)

      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"
      # Frame must finish loading before scrolling — otherwise
      # `#syncFrameUrlToBrowser` fires after the picker has updated
      # the URL and clobbers the change.
      assert_selector "turbo-frame#assessment-matrix[complete]", visible: :all

      scroll_card_into_band(@cap2_stable)

      # URL should now name cap2 so a reload lands on it. Poll —
      # scroll-driven focus updates via replaceState fire on the
      # picker's settle pass, which can take a couple of frames after
      # the scroll lands on slower CI runners.
      url_synced = wait_until_js do
        page.current_url.include?("capability=#{@cap2_stable}")
      end
      unless url_synced
        # Surface the picker's view of the world to the CI log.
        diag = page.execute_script(<<~JS)
          const matrixEl = document.querySelector("[data-controller~='matrix']");
          const ctrl = window.Stimulus.getControllerForElementAndIdentifier(matrixEl, "matrix");
          const cards = (ctrl?.cardTargets || []).map(c => {
            const r = c.getBoundingClientRect();
            return { stable: c.dataset.capabilityStableId, top: r.top, bottom: r.bottom };
          });
          const stickyH = parseFloat(
            getComputedStyle(document.documentElement).getPropertyValue("--sticky-header-h")
          ) || 0;
          return JSON.stringify({
            url: window.location.href,
            scrollY: window.scrollY,
            stickyH: stickyH,
            viewportH: window.innerHeight,
            currentFocus: ctrl?.currentFocus,
            sawUserScroll: ctrl?._sawUserScroll,
            suppressionScrollRenew: ctrl?._suppressionScrollRenew,
            cards: cards
          });
        JS
        flunk "scroll-driven focus did not update URL to cap2; diag=#{diag}"
      end

      visit page.current_url
      wait_for_stimulus "matrix"

      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='true']"
    end
  end

  context "capability focus scroll" do
    should "scroll the clicked capability card into view when its card lives off-screen" do
      # Smaller viewport so cap2 sits below the fold and a real scroll
      # is required to bring it into view.
      page.driver.browser.manage.window.resize_to(900, 600)

      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      # Pre-condition: cap2's card top is below the viewport bottom.
      pre = page.execute_script(<<~JS)
        const card = document.querySelector(
          "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}']"
        );
        const r = card.getBoundingClientRect();
        return JSON.stringify({ top: r.top, viewportH: window.innerHeight });
      JS
      pre_state = JSON.parse(pre)
      assert pre_state["top"] > pre_state["viewportH"],
        "expected cap2 to start below the viewport; got top=#{pre_state['top']}, viewportH=#{pre_state['viewportH']}"

      click_card_header(@cap2_stable)

      # Smooth scroll + settle pass takes ~700ms; wait for it before
      # measuring. getBoundingClientRect can't be polled by Capybara
      # selectors directly so a short fixed wait is the simplest contract.
      sleep 1.2

      post = page.execute_script(<<~JS)
        const card = document.querySelector(
          "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}']"
        );
        const r = card.getBoundingClientRect();
        return JSON.stringify({ top: r.top, bottom: r.bottom, viewportH: window.innerHeight });
      JS
      post_state = JSON.parse(post)
      assert post_state["top"] >= 0 && post_state["top"] < post_state["viewportH"],
        "expected cap2 to scroll into view; got top=#{post_state['top']}, viewportH=#{post_state['viewportH']}"
    end
  end

  context "capability focus ring" do
    should "stamp data-focused on the clicked card and clear it elsewhere" do
      visit assessment_path(@assignment)
      wait_for_stimulus "matrix"

      click_card_header(@cap2_stable)

      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='true']"
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap1_stable}'][data-focused='false']"

      # Re-clicking the same card header drops back to category focus —
      # the ring clears on both cards.
      click_card_header(@cap2_stable)

      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap2_stable}'][data-focused='false']"
      assert_selector "[data-matrix-target='card'][data-capability-stable-id='#{@cap1_stable}'][data-focused='false']"
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

# frozen_string_literal: true

# Helpers for waiting on Stimulus controller readiness and performing
# CI-resilient toggle interactions in system tests.
#
# Stimulus controllers that extend BaseController set a `data-connected`
# attribute on their element when connected. These helpers wait for that
# signal before interacting with Stimulus-driven UI, preventing flaky
# tests on slow CI runners where action handlers aren't attached yet
# when Capybara clicks.
#
# == Toggle helpers
#
# On CI runners where Chrome's JS event loop is starved, a Selenium click
# can be silently lost. The toggle helpers click, verify the expected state
# change, retry once if the click was lost, and assert the final visible
# state. Each public helper encodes a specific controller's toggle contract.
#
# Usage:
#   wait_for_stimulus "framework-explorer"
#   open_dropdown
#   toggle_sidebar
#   toggle_role_pane
#   toggle_panel
#   expand_matrix_row("#capability-name-#{stable_id}")
module StimulusHelpers
  # Waits until the named Stimulus controller has connected.
  #
  # @param controller_name [String] the Stimulus controller identifier
  #   (e.g. "framework-explorer", "dropdown", "matrix")
  # @param scope [String, nil] optional CSS selector to scope the search
  #   (e.g. "[data-framework-explorer-target='rolePaneToggle']")
  def wait_for_stimulus(controller_name, scope: nil)
    selector = "[data-controller~='#{controller_name}'][data-connected]"
    selector = "#{scope} #{selector}" if scope
    assert_selector selector, visible: :all
  end

  # Opens a dropdown menu.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def open_dropdown(scope: nil)
    wait_for_stimulus "dropdown", scope: scope
    stimulus_toggle(
      "[data-action='dropdown#toggle']",
      visible_selector: "[role='menu']",
      verify_selector: "[data-action='dropdown#toggle'][aria-expanded='true']",
      scope: scope
    )
  end

  # Opens the mobile sidebar drawer.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def toggle_sidebar(scope: nil)
    # Sidebar doesn't extend BaseController. Wait for target registration
    # as a readiness signal.
    drawer_selector = "[data-sidebar-target='drawer']"
    drawer_selector = "#{scope} #{drawer_selector}" if scope
    assert_selector drawer_selector, visible: :all

    stimulus_toggle(
      "[data-action='sidebar#toggle']",
      visible_selector: "[data-sidebar-target='drawer']",
      scope: scope
    )
  end

  # Opens the framework explorer role pane.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def toggle_role_pane(scope: nil)
    wait_for_stimulus "framework-explorer", scope: scope
    stimulus_toggle(
      "[data-action='framework-explorer#toggleRolePane']",
      visible_selector: "[data-framework-explorer-target='rolePane']",
      scope: scope
    )
  end

  # Opens the framework explorer context (right) pane.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def toggle_context_pane(scope: nil)
    wait_for_stimulus "framework-explorer", scope: scope
    stimulus_toggle(
      "[data-action='framework-explorer#toggleContextPane']",
      visible_selector: "[data-framework-explorer-target='contextPane']",
      scope: scope
    )
  end

  # Opens a panel (e.g. scoring panel).
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def toggle_panel(scope: nil)
    # Panel doesn't extend BaseController. Wait for target registration
    # as a readiness signal.
    panel_selector = "[data-panel-target='panel']"
    panel_selector = "#{scope} #{panel_selector}" if scope
    assert_selector panel_selector, visible: :all

    stimulus_toggle(
      "[data-action='panel#toggle']",
      visible_selector: "[data-panel-target='panel']",
      scope: scope
    )
  end

  # Expands a matrix row by clicking the given capability selector.
  #
  # @param capability_selector [String] CSS selector for the capability
  #   element to click (e.g. "#capability-name-{stable_id}")
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def expand_matrix_row(capability_selector, scope: nil)
    wait_for_stimulus "matrix", scope: scope
    stimulus_toggle(
      capability_selector,
      visible_selector: "[data-matrix-target='expandedRow']",
      scope: scope
    )
  end

  # Performs a click via the given block and retries it once if the expected
  # text or selector does not appear within a short window. Use this for
  # Turbo Drive navigation clicks and Turbo Frame link clicks that may be
  # silently dropped when Chrome's event loop is starved on slow CI runners.
  #
  # @param expect_text [String, nil] text that should appear after the click
  # @param expect_selector [String, nil] CSS selector that should appear
  #   after the click (alternative to +expect_text+)
  # @yield the block performing the click (e.g. `click_on "Save"` inside a `within`)
  #
  # @example Click a Turbo Frame link in a panel and retry if dropped
  #   click_with_retry(expect_text: "Execution") do
  #     within("#scoring-panel") { click_on "Delivering" }
  #   end
  def click_with_retry(expect_text: nil, expect_selector: nil)
    raise ArgumentError, "expect_text or expect_selector required" unless expect_text || expect_selector

    yield

    # Wait long enough for a slow CI Turbo Frame round-trip before deciding
    # the click was dropped. Too short (2s) and the retry fires mid-navigation,
    # potentially interfering with the in-flight fetch.
    landed =
      if expect_text
        page.has_text?(expect_text, wait: 8)
      else
        page.has_css?(expect_selector, wait: 8)
      end

    yield unless landed

    # The final wait also needs to be generous: when we retry a dropped click,
    # the fresh navigation + Turbo round-trip itself can exceed Capybara's
    # default on a starved CI runner. We've observed cases where even an 8s
    # wait misses on the first runner cycle of the day — bumping to match
    # Capybara's default_max_wait_time gives us full headroom.
    if expect_text
      assert_text expect_text, wait: Capybara.default_max_wait_time
    else
      assert_selector expect_selector, wait: Capybara.default_max_wait_time
    end
  end

  # Clicks a link by locator, retrying with a JS-dispatched click if the
  # Capybara pointer click is dropped. Selenium's synthetic click is
  # vulnerable on starved CI runners; +click_with_retry+ retries the same
  # Capybara click which can be dropped a second time. JS dispatch is
  # synchronous and bypasses pointer hit-testing entirely, so the second
  # attempt is guaranteed to fire.
  #
  # @param locator [String] the link text/locator
  # @param expect_text [String, nil] text expected on destination
  # @param expect_selector [String, nil] selector expected on destination
  def click_link_with_js_fallback(locator, expect_text: nil, expect_selector: nil)
    raise ArgumentError, "expect_text or expect_selector required" unless expect_text || expect_selector

    click_link locator
    return if landed?(expect_text, expect_selector, wait: 8)

    # First click was dropped. Find the link by visible text and dispatch
    # a synthetic click via JS — bypasses Selenium pointer hit-testing.
    page.execute_script(<<~JS, locator)
      const text = arguments[0];
      const links = Array.from(document.querySelectorAll("a"));
      const link = links.find(a => a.textContent.trim() === text || a.textContent.includes(text));
      if (link) link.click();
    JS

    if expect_text
      assert_text expect_text, wait: Capybara.default_max_wait_time
    else
      assert_selector expect_selector, wait: Capybara.default_max_wait_time
    end
  end

  # Like +click_link_with_js_fallback+ but for buttons (incl. form submits).
  #
  # @param locator [String] button text/locator
  # @param expect_text [String, nil] text expected after the click
  # @param expect_selector [String, nil] selector expected after the click
  def click_button_with_js_fallback(locator, expect_text: nil, expect_selector: nil)
    raise ArgumentError, "expect_text or expect_selector required" unless expect_text || expect_selector

    click_button locator
    return if landed?(expect_text, expect_selector, wait: 8)

    # First click dropped — fall back to JS click, which fires synchronously
    # and bypasses Selenium pointer hit-testing.
    page.execute_script(<<~JS, locator)
      const text = arguments[0];
      const buttons = Array.from(document.querySelectorAll("button, input[type='submit']"));
      const btn = buttons.find(b => {
        const label = (b.textContent || b.value || "").trim();
        return label === text || label.includes(text);
      });
      if (btn) btn.click();
    JS

    if expect_text
      assert_text expect_text, wait: Capybara.default_max_wait_time
    else
      assert_selector expect_selector, wait: Capybara.default_max_wait_time
    end
  end

  def landed?(expect_text, expect_selector, wait:)
    if expect_text
      page.has_text?(expect_text, wait: wait)
    else
      page.has_css?(expect_selector, wait: wait)
    end
  end

  # Stubs +window.confirm+ to always return true, then runs the block.
  # Use for clicks that submit forms with +data-turbo-confirm+ when the
  # action under test is the form submission, not the dialog itself.
  #
  # On slow CI runners, Capybara's +accept_confirm+ has a race window
  # between the click and the dialog appearing — when the JS event loop
  # is starved, the click can fire before Capybara's modal handler is
  # registered, so the dialog appears, fires confirm() instantly with no
  # handler, and is gone before Capybara polls. Stubbing +window.confirm+
  # eliminates the race entirely: Turbo's submit-listener calls confirm()
  # synchronously and our stub returns true with no dialog ever showing.
  #
  # @yield the block performing the click that triggers the confirm dialog
  def auto_confirm
    page.execute_script("window.__originalConfirm = window.confirm; window.confirm = () => true;")
    yield
  ensure
    page.execute_script("if (window.__originalConfirm) { window.confirm = window.__originalConfirm; }")
  end

  # Wraps Capybara's +accept_confirm+ to retry up to two more times if the
  # dialog never appears — on slow CI runners, the click that should
  # trigger Turbo's +data-turbo-confirm+ dialog is occasionally dropped.
  # Without retry, +Capybara::ModalNotFound+ raises on the first attempt.
  #
  # Forwards any positional matcher (text or regex) and the +wait+ kwarg
  # straight through to +accept_confirm+, so it's a drop-in replacement.
  #
  # @yield the block performing the click that triggers the confirm dialog
  def accept_confirm_with_retry(*args, wait: 5, &block)
    # Turbo intercepts form submissions with +data-turbo-confirm+ at submit
    # time. If +window.Turbo+ isn't yet defined when the click fires, the
    # form submits directly and no dialog appears. Wait for Turbo to load
    # before the first attempt so the dialog has the best chance of showing.
    wait_for_turbo_ready

    attempts = 0
    begin
      attempts += 1
      accept_confirm(*args, wait: wait, &block)
    rescue Capybara::ModalNotFound
      raise if attempts >= 3

      # Brief pause lets any in-flight Turbo + Stimulus boot finish before
      # the next click — clicks fired during the boot are the typical cause
      # of dropped Turbo-confirm dialogs.
      sleep 0.5
      retry
    end
  end

  # Polls the browser until +window.Turbo+ is defined. Turbo's submission
  # interception relies on this global being installed — clicks fired
  # before it loads will bypass +data-turbo-confirm+ entirely.
  def wait_for_turbo_ready(wait: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
    loop do
      return if page.evaluate_script("typeof Turbo !== 'undefined'")
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  # Clicks a rating frequency button and retries once if the expected
  # ring-1 indicator never appears. Wraps the recurring pattern in
  # rating-cell tests where a Capybara pointer click can be silently
  # dropped on slow CI runners. Re-clicking is safe because the cell is
  # still in its un-rated state when the first click was lost.
  #
  # @param cell_selector [String] e.g. "#rating-{stable}-{level}"
  # @param frequency [String] button text — "Some" / "Most" / "Consistently"
  def click_rating_frequency(cell_selector, frequency)
    find("#{cell_selector} button", text: frequency).click

    return if page.has_css?("#{cell_selector} button.ring-1", text: frequency, wait: 4)

    find("#{cell_selector} button", text: frequency).click
  end

  # Waits until Turbo Drive / Turbo Frame are idle — no busy frames, no
  # in-flight navigation. Use after a click that triggers Turbo navigation
  # and before reading state that depends on the destination DOM having
  # committed.
  #
  # @param wait [Integer] seconds to wait for idle (default Capybara's max)
  def wait_for_turbo_idle(wait: Capybara.default_max_wait_time)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait

    loop do
      idle = page.evaluate_script(<<~JS)
        (() => {
          if (document.querySelector('turbo-frame[busy]')) return false;
          if (document.querySelector('html[aria-busy="true"]')) return false;
          return true;
        })()
      JS
      return if idle

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
  end

  private

  # Clicks a toggle element via JS-dispatch and asserts the visible state.
  #
  # Capybara's default click simulates a real user pointer click, which on
  # slow CI runners has been observed to be silently dropped when Chrome's
  # JS event loop is starved, or when the target is momentarily obscured by
  # a sticky element, scroll position, or mid-flight layout.
  #
  # JS-dispatched click is synchronous (the Stimulus action handler runs
  # inline before +execute_script+ returns) and bypasses pointer
  # hit-testing entirely. In practice we have still seen rare cases on
  # 2-core CI runners where the dispatch returns before the handler has
  # finished its DOM mutations, or where the controller hadn't yet attached
  # delegated listeners despite +data-connected+ being set. To stay
  # deterministic without ping-pong, we re-dispatch the click only if the
  # toggle is still in its un-toggled state — re-clicking a toggle that has
  # already moved to the "visible" state would undo the first click, which
  # is exactly the bug we want to avoid.
  #
  # @param toggle_selector [String] CSS selector for the element to click
  # @param visible_selector [String] CSS selector that should become
  #   visible after the toggle (used for the final assertion)
  # @param verify_selector [String, nil] fast synchronous check selector
  #   (e.g. aria-expanded attribute). Checked with `visible: :all` since
  #   the attribute may be on a non-visible element. When provided, asserted
  #   before +visible_selector+ so animated transitions don't mask a
  #   synchronously-applied state change.
  # @param scope [String, nil] optional CSS scope prefix
  def stimulus_toggle(toggle_selector, visible_selector:, verify_selector: nil, scope: nil)
    toggle_selector = "#{scope} #{toggle_selector}" if scope
    scoped_visible = scope ? "#{scope} #{visible_selector}" : visible_selector
    scoped_verify = verify_selector && (scope ? "#{scope} #{verify_selector}" : verify_selector)

    # Idempotent: if the target is already visible (e.g. the framework-explorer
    # context pane is open by default in edit mode), the caller asked for "make
    # it visible" and it already is — no click needed.
    return if page.has_css?(scoped_visible, visible: true, wait: 0)

    # Surface genuine missing-target bugs. +assert_selector+ allows multiple
    # matches (unlike +find+), so callers that pass non-unique selectors like
    # `tr[data-capability-id]` still work — +querySelector+ below picks the
    # first one, which is intentional.
    assert_selector toggle_selector

    dispatch_js_click(toggle_selector)

    # Short window for the synchronous handler to flip the visible state.
    # If it lands, we're done after the standard verify+visible asserts.
    if page.has_css?(scoped_visible, visible: true, wait: 3)
      assert_selector scoped_verify, visible: :all, wait: 5 if scoped_verify
      assert_selector scoped_visible, visible: true
      return
    end

    # First click was dropped or the controller hadn't fully wired its
    # action when we dispatched. Re-dispatch only because the toggle is
    # still in its un-toggled state — re-clicking a toggle that has already
    # moved to "visible" would undo the first click.
    dispatch_js_click(toggle_selector)

    assert_selector scoped_verify, visible: :all, wait: 5 if scoped_verify
    assert_selector scoped_visible, visible: true
  end

  def dispatch_js_click(selector)
    page.execute_script(<<~JS, selector)
      const el = document.querySelector(arguments[0]);
      if (el) el.click();
    JS
  end
end

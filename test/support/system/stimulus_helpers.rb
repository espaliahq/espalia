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
        page.has_text?(expect_text, wait: 4)
      else
        page.has_css?(expect_selector, wait: 4)
      end

    yield unless landed

    if expect_text
      assert_text expect_text
    else
      assert_selector expect_selector
    end
  end

  private

  # Clicks a toggle element and retries once if the action was lost.
  #
  # On slow CI runners, Selenium clicks can be silently dropped when
  # Chrome's JS event loop is starved. This method clicks, checks a
  # verification condition, retries once if the click didn't take
  # effect, and asserts the final visible state.
  #
  # @param toggle_selector [String] CSS selector for the element to click
  # @param visible_selector [String] CSS selector that should become
  #   visible after a successful toggle (used for the final assertion)
  # @param verify_selector [String, nil] fast synchronous check selector
  #   (e.g. aria-expanded attribute). Checked with `visible: :all` since
  #   the attribute may be on a non-visible element. Falls back to
  #   +visible_selector+ with `visible: true` when nil.
  # @param scope [String, nil] optional CSS scope prefix
  def stimulus_toggle(toggle_selector, visible_selector:, verify_selector: nil, scope: nil)
    toggle_selector = "#{scope} #{toggle_selector}" if scope
    scoped_visible = scope ? "#{scope} #{visible_selector}" : visible_selector
    scoped_verify = verify_selector && (scope ? "#{scope} #{verify_selector}" : verify_selector)

    find(toggle_selector).click

    # Retry up to twice if the click didn't take effect — the event loop can
    # starve on slow CI runners, silently dropping the first click even after
    # Stimulus reports connected. Waits between retries must be long enough
    # to distinguish "click was lost" from "click landed but the handler is
    # still running" — retrying mid-handler on a toggle action re-toggles and
    # hides the target.
    2.times do
      settled = scoped_verify ? page.has_css?(scoped_verify, visible: :all, wait: 5)
                              : page.has_css?(scoped_visible, visible: true, wait: 5)
      break if settled

      # Re-resolve the element — the earlier click may have triggered a
      # Turbo frame swap that replaced the original node.
      target = first(toggle_selector, wait: 1)
      target&.click
    end

    assert_selector scoped_visible, visible: true, wait: 5
  end
end

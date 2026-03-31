# frozen_string_literal: true

# Helpers for waiting on Stimulus controller readiness in system tests.
#
# Stimulus controllers that extend BaseController set a `data-connected`
# attribute on their element when connected. These helpers wait for that
# signal before interacting with Stimulus-driven UI, preventing flaky
# tests on slow CI runners where action handlers aren't attached yet
# when Capybara clicks.
#
# Usage:
#   wait_for_stimulus "framework-explorer"
#   click_button "Roles"
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

  # Opens a dropdown menu by clicking the toggle and waiting for the
  # menu to become visible. On CI runners where Chrome's event loop
  # is starved, a Selenium click can be silently lost. This helper
  # checks `aria-expanded` (set synchronously by the dropdown
  # controller) and retries the click once if it didn't take effect.
  #
  # @param scope [String, nil] optional CSS selector to scope the toggle
  def open_dropdown(scope: nil)
    wait_for_stimulus "dropdown", scope: scope
    toggle_selector = "[data-action='dropdown#toggle']"
    toggle_selector = "#{scope} #{toggle_selector}" if scope

    find(toggle_selector).click

    # aria-expanded is updated synchronously by the controller.
    # If it's still "false" after a brief wait, the click was lost — retry.
    unless page.has_css?("#{toggle_selector}[aria-expanded='true']", wait: 1)
      find(toggle_selector).click
    end

    assert_selector "[role='menu']", visible: true
  end
end

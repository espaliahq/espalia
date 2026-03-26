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
end

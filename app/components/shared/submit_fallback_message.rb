# frozen_string_literal: true

# The pre-existing live region the `submit-fallback` Stimulus controller
# injects transport-failure text into (audit issue #316). Rendered empty and
# hidden so the alert region exists before any message lands (WCAG 4.1.3);
# the controller owns showing/hiding and the copy.
#
# @example next to a rating pill (absolute positioning)
#   render Components::Shared::SubmitFallbackMessage.new(
#     classes: "absolute left-0 top-full mt-1 z-20 w-max max-w-64"
#   )
class Components::Shared::SubmitFallbackMessage < Components::Base
  # A small danger Kit::Alert's look as one CSS class (application.css), because
  # one sits beside every rating pill. Public so the frame-load error and the
  # field editor share it.
  PANEL_CLASSES = "kit-alert-panel"

  # @param classes [String] positioning/sizing utilities for the host surface
  def initialize(classes: "")
    @classes = classes
  end

  # Renders the empty, hidden alert region the controller targets.
  # @return [void]
  def view_template
    div(
      role: "alert", hidden: true,
      class: "#{@classes} #{PANEL_CLASSES}",
      data: { submit_fallback_target: "message" }
    ) { }
  end
end

# frozen_string_literal: true

# The pre-existing live region the `submit-fallback` Stimulus controller
# injects transport-failure text into (audit issue #316). Rendered empty and
# hidden so the alert region exists before any message lands (WCAG 4.1.3);
# the controller owns showing/hiding and the copy.
#
# @example next to a rating pill (absolute positioning)
#   render Components::Kit::SubmitFallbackMessage.new(
#     classes: "absolute left-0 top-full mt-1 z-20 w-max max-w-64"
#   )
class Components::Kit::SubmitFallbackMessage < Components::Base
  # The red inline-error panel. Public so other surfaces that render the same
  # "something went wrong here" panel outside this component's live region —
  # the evidence modal's frame-load error — share one definition instead of
  # retyping the class string.
  PANEL_CLASSES = "p-2 rounded-md bg-red-50 dark:bg-red-900/20 " \
                  "border border-red-200 dark:border-red-800 text-xs text-red-700 dark:text-red-300"

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

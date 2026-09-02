# frozen_string_literal: true

# The failure state for a lazy turbo-frame, revealed by the `frame-error`
# Stimulus controller in place of the frame's stuck "Loading…" placeholder
# (audit issues #328 / #365).
#
# Rendered hidden so the alert region exists before the failure does (WCAG
# 4.1.3), and `tabindex="-1"` so the controller can move focus here — on a
# repeat failure the Retry the user just pressed is inside the frame being
# hidden, and focus would otherwise fall out of the dialog to <body>.
#
# `closeable:` adds a Close beside Retry. On a modal that is not a nicety:
# hiding the frame also hides the form's own ×/Cancel, so without it a failed
# load has no exit at all.
#
# @example inside a modal panel that owns the `modal` + `frame-error` controllers
#   render Components::Kit::FrameLoadError.new(
#     id: "evidence-modal-error", closeable: true,
#     message: "Couldn't load the form. Try again — if it keeps failing, close this and reload the page."
#   )
class Components::Kit::FrameLoadError < Components::Base
  # The neutral secondary-button treatment (same utilities as the evidence
  # forms' SECONDARY_BTN — owned here so a Kit component doesn't reach into a
  # Views constant).
  BUTTON_CLASSES = "inline-flex items-center min-h-11 px-3 rounded-md border border-gray-300 " \
                   "dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-200 cursor-pointer"

  # Failure-agnostic by design: one state covers a dropped connection, a 500,
  # and an expired session, so "check your connection" would misdirect two of
  # the three.
  DEFAULT_MESSAGE = "Couldn't load this. Try again — if it keeps failing, reload the page."

  # @param id [String] element id (stable, for tests and deep links)
  # @param message [String] failure copy
  # @param closeable [Boolean] render a Close (dispatches `modal#close`)
  # @param classes [String] layout utilities for the host surface
  def initialize(id:, message: DEFAULT_MESSAGE, closeable: false, classes: "p-6 space-y-3")
    @id = id
    @message = message
    @closeable = closeable
    @classes = classes
  end

  # @return [void]
  def view_template
    div(id: @id, role: "alert", hidden: true, tabindex: "-1",
        class: @classes, data: { frame_error_target: "error" }) do
      p(class: Components::Kit::SubmitFallbackMessage::PANEL_CLASSES) { @message }
      div(class: "flex gap-2") do
        button(type: "button", data: { action: "frame-error#retry" }, class: BUTTON_CLASSES) { "Retry" }
        if @closeable
          button(type: "button", data: { action: "modal#close" }, class: BUTTON_CLASSES) { "Close" }
        end
      end
    end
  end
end

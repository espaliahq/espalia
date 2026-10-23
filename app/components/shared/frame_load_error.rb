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
#   render Components::Shared::FrameLoadError.new(
#     id: "evidence-modal-error", subject: "the form", closeable: true
#   )
class Components::Shared::FrameLoadError < Components::Base
  # Kit::Button's outline neutral look as one CSS class (application.css): every
  # expanded-row placeholder in the explorer's matrix ships one, and the
  # component's utility string would repeat per row (#383). The evidence forms'
  # SECONDARY_BTN point here too.
  BUTTON_CLASSES = "kit-btn-secondary"

  # What the reader was trying to open, when the caller doesn't name it.
  DEFAULT_SUBJECT = "this"

  # The tail must agree with whether a Close is actually offered — which is why
  # the sentence is built here from `closeable:` rather than passed in as free
  # text per site, where the two could contradict each other.
  CLOSEABLE_TAIL = "close this and reload the page"
  TAIL = "reload the page"

  # @param id [String] element id (stable, for tests and deep links)
  # @param subject [String] what failed to load, as a noun phrase ("the form")
  # @param closeable [Boolean] render a Close (dispatches `modal#close`)
  # @param classes [String] layout utilities for the host surface
  # @param retry_action [String] Stimulus action the Retry dispatches — the
  #   `frame-error` controller's by default; a host that reloads by other
  #   means (the matrix's on-demand expanded row) names its own
  def initialize(id:, subject: DEFAULT_SUBJECT, closeable: false, classes: "p-6 space-y-3",
                 retry_action: "frame-error#retry")
    @id = id
    @subject = subject
    @closeable = closeable
    @classes = classes
    @retry_action = retry_action
  end

  # Failure-agnostic by design: one state covers a dropped connection, a 500,
  # and an expired session, so "check your connection" would misdirect two of
  # the three.
  #
  # @return [String]
  def message
    "Couldn't load #{@subject}. Try again — if it keeps failing, " \
      "#{@closeable ? CLOSEABLE_TAIL : TAIL}."
  end

  # @return [void]
  def view_template
    div(id: @id, role: "alert", hidden: true, tabindex: "-1",
        class: @classes, data: { frame_error_target: "error" }) do
      p(class: Components::Shared::SubmitFallbackMessage::PANEL_CLASSES) { message }
      div(class: "flex gap-2") do
        button(type: "button", data: { action: @retry_action }, class: BUTTON_CLASSES) { "Retry" }
        if @closeable
          button(type: "button", data: { action: "modal#close" }, class: BUTTON_CLASSES) { "Close" }
        end
      end
    end
  end
end

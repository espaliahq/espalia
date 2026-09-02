# frozen_string_literal: true

# Modal shell that hosts the "request evidence" form. A bare overlay/panel
# (driven by the shared `modal` controller) wrapping the lazy
# `#evidence-request-modal` turbo-frame (driven by `request-evidence#load`).
#
# Rendered once per assessment surface, INSIDE the element that owns the
# `modal` + `request-evidence` controllers. Because that element ALSO hosts the
# evidence modal's overlay, every trigger must name its overlay via
# `data-modal-target-id` (framework-explorer Hard-Won Lesson 19) — this one is
# `evidence-request-modal-overlay`.
#
# The panel carries the shared `frame-error` controller: a failed GET would
# otherwise leave the modal on "Loading…" forever with no way out at all — this
# modal's own × lives inside the frame that never loaded (audit issue #365).
#
# It carries `submit-fallback` for the same reason the evidence modal does
# (audit issue #316): a transport-level failure on Send is otherwise completely
# silent, and a 5xx HTML body would be rendered as the page — destroying the
# recipients and message the user just assembled. The live region sits OUTSIDE
# the frame so it survives the frame swap a failed submit can trigger.
class Views::Evidence::RequestModalShell < Views::Base
  def view_template
    div(id: "evidence-request-modal-overlay",
        data: { modal_target: "overlay",
                modal_dirty_guard: "Discard your unsaved request?" },
        class: "fixed inset-0 z-40 hidden items-center justify-center bg-black/40 px-4",
        role: "dialog", aria: { modal: "true" }) do
      div(class: "w-full max-w-xl max-h-[90vh] overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl",
          tabindex: "-1",
          data: { modal_target: "panel",
                  controller: "submit-fallback frame-error",
                  submit_fallback_text_value: "Couldn't send your request — check your connection " \
                                              "and try again. Your recipients are still here.",
                  action: "turbo:before-fetch-response->submit-fallback#beforeFetchResponse " \
                          "turbo:submit-start->submit-fallback#submitStart " \
                          "turbo:submit-end->submit-fallback#submitEnd " \
                          "modal:open@window->submit-fallback#submitStart " \
                          "turbo:before-fetch-request->frame-error#requestStarted " \
                          "turbo:fetch-request-error->frame-error#loadFailed " \
                          "turbo:frame-missing->frame-error#loadFailed " \
                          "turbo:before-fetch-response->frame-error#responseReceived " \
                          "turbo:frame-load->frame-error#loadSucceeded" }) do
        render Components::Kit::SubmitFallbackMessage.new(classes: "mx-5 mt-4")
        turbo_frame_tag("evidence-request-modal", loading: "lazy",
                        data: { request_evidence_target: "frame", frame_error_target: "frame" }) do
          div(class: "p-6 text-sm text-gray-500 dark:text-gray-400") { "Loading…" }
        end
        render Components::Kit::FrameLoadError.new(
          id: "evidence-request-modal-error", closeable: true,
          message: "Couldn't load the request form. Try again — if it keeps failing, close this and reload the page."
        )
      end
    end
  end
end

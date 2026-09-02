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
                  controller: "frame-error",
                  action: "turbo:before-fetch-request->frame-error#requestStarted " \
                          "turbo:fetch-request-error->frame-error#loadFailed " \
                          "turbo:frame-missing->frame-error#loadFailed " \
                          "turbo:before-fetch-response->frame-error#responseReceived " \
                          "turbo:frame-load->frame-error#loadSucceeded" }) do
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

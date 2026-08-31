# frozen_string_literal: true

# The shared modal shell that hosts the unified evidence form. A bare
# overlay/panel (driven by the `modal` controller) wrapping the lazy
# `#evidence-modal` turbo-frame (driven by `evidence-modal#load`). A trigger
# sets the frame `src` and opens the overlay; the server renders the form.
#
# The frame's inline fallback is a "Loading…" placeholder. When the frame's
# GET fails outright (network error, or a response carrying no matching frame)
# Turbo leaves that placeholder in place forever — a modal stuck on "Loading…"
# with no error and no way forward (audit issue #328). The error state below
# is rendered hidden and revealed by `evidence-modal#loadFailed`, giving the
# failure a voice and a Retry.
#
# Rendered once per surface, INSIDE the element that owns both the `modal` and
# `evidence-modal` controllers. On the assessment screen that element also
# carries `assessment-sync`, so the modal's submit lands inside the suppress
# window (no full-matrix reload).
class Views::Evidence::ModalShell < Views::Base
  def view_template
    div(id: "evidence-modal-overlay",
        data: { modal_target: "overlay",
                modal_dirty_guard: "Discard your unsaved feedback / evidence?" },
        class: "fixed inset-0 z-40 hidden items-center justify-center bg-black/40 px-4",
        role: "dialog", aria: { modal: "true" }) do
      div(class: "w-full max-w-xl lg:max-w-2xl xl:max-w-3xl max-h-[90vh] overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl",
          tabindex: "-1",
          data: { modal_target: "panel",
                  controller: "submit-fallback",
                  submit_fallback_text_value: "Couldn't save your feedback — check your connection and try again. Your text is still here.",
                  action: "turbo:before-fetch-response->submit-fallback#beforeFetchResponse " \
                          "turbo:submit-start->submit-fallback#submitStart " \
                          "turbo:submit-end->submit-fallback#submitEnd " \
                          "modal:open@window->submit-fallback#submitStart " \
                          "turbo:fetch-request-error->evidence-modal#loadFailed " \
                          "turbo:frame-missing->evidence-modal#loadFailed " \
                          "turbo:frame-load->evidence-modal#loadSucceeded" }) do
        render Components::Kit::SubmitFallbackMessage.new(classes: "mx-5 mt-4")
        turbo_frame_tag("evidence-modal", loading: "lazy", data: { evidence_modal_target: "frame" }) do
          div(class: "p-6 text-sm text-gray-500 dark:text-gray-400") { "Loading…" }
        end
        load_error
      end
    end
  end

  private

  # The frame-load failure state: hidden until `evidence-modal#loadFailed`
  # reveals it (in place of the "Loading…" placeholder), with a Retry that
  # re-fetches the frame. `role="alert"` so the failure is announced, not
  # only seen.
  # @return [void]
  def load_error
    div(id: "evidence-modal-error", role: "alert", hidden: true,
        class: "p-6 space-y-3", data: { evidence_modal_target: "error" }) do
      p(class: "p-2 rounded-md bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 " \
               "text-xs text-red-700 dark:text-red-300") do
        "Couldn't load the form — check your connection and try again."
      end
      button(type: "button", data: { action: "evidence-modal#retry" },
             class: "inline-flex items-center min-h-11 px-3 rounded-md border border-gray-300 " \
                    "dark:border-gray-600 text-sm font-medium text-gray-700 dark:text-gray-200 " \
                    "cursor-pointer") { "Retry" }
    end
  end
end

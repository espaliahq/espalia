# frozen_string_literal: true

# The shared modal shell that hosts the unified evidence form. A bare
# overlay/panel (driven by the `modal` controller) wrapping the lazy
# `#evidence-modal` turbo-frame (driven by `evidence-modal#load`). A trigger
# sets the frame `src` and opens the overlay; the server renders the form.
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
          data: { modal_target: "panel",
                  controller: "submit-fallback",
                  submit_fallback_text_value: "Couldn't save your feedback — check your connection and try again. Your text is still here.",
                  action: "turbo:before-fetch-response->submit-fallback#beforeFetchResponse " \
                          "turbo:submit-start->submit-fallback#submitStart " \
                          "turbo:submit-end->submit-fallback#submitEnd" }) do
        div(
          role: "alert", hidden: true,
          class: "mx-5 mt-4 p-2 rounded-md bg-red-50 dark:bg-red-900/20 " \
                 "border border-red-200 dark:border-red-800 text-xs text-red-700 dark:text-red-300",
          data: { submit_fallback_target: "message" }
        ) { }
        turbo_frame_tag("evidence-modal", loading: "lazy", data: { evidence_modal_target: "frame" }) do
          div(class: "p-6 text-sm text-gray-500 dark:text-gray-400") { "Loading…" }
        end
      end
    end
  end
end

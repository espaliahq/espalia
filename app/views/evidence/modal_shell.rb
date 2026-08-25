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
          data: { modal_target: "panel" }) do
        turbo_frame_tag("evidence-modal", loading: "lazy", data: { evidence_modal_target: "frame" }) do
          div(class: "p-6 text-sm text-gray-500 dark:text-gray-400") { "Loading…" }
        end
      end
    end
  end
end

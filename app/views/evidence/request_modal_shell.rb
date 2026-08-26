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
class Views::Evidence::RequestModalShell < Views::Base
  def view_template
    div(id: "evidence-request-modal-overlay",
        data: { modal_target: "overlay",
                modal_dirty_guard: "Discard your unsaved request?" },
        class: "fixed inset-0 z-40 hidden items-center justify-center bg-black/40 px-4",
        role: "dialog", aria: { modal: "true" }) do
      div(class: "w-full max-w-xl max-h-[90vh] overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl",
          data: { modal_target: "panel" }) do
        turbo_frame_tag("evidence-request-modal", loading: "lazy", data: { request_evidence_target: "frame" }) do
          div(class: "p-6 text-sm text-gray-500 dark:text-gray-400") { "Loading…" }
        end
      end
    end
  end
end

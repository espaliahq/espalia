# frozen_string_literal: true

# The shared modal shell that hosts the unified evidence form. A headerless
# embedded `Kit::Modal` (driven by the `modal` controller) wrapping the lazy
# `#evidence-modal` turbo-frame (driven by `evidence-modal#load`). A trigger
# sets the frame `src` and opens the overlay; the server renders the form.
#
# The frame's inline fallback is a "Loading…" placeholder. When the frame's
# GET fails — the network drops, the response carries no matching frame, or it
# isn't HTML at all (a proxy's text/plain 502, which Turbo discards in total
# silence) — that placeholder stands forever: a modal stuck on "Loading…" with
# no error and no way forward (audit issue #328). The shared `frame-error`
# controller + `Shared::FrameLoadError` block give the failure a voice, a Retry,
# and — since the form's own ×/Cancel went down with the hidden frame — a way
# out.
#
# Rendered once per surface, INSIDE the element that owns both the `modal` and
# `evidence-modal` controllers. On the assessment screen that element also
# carries `assessment-sync`, so the modal's submit lands inside the suppress
# window (no full-matrix reload).
class Views::Evidence::ModalShell < Views::Base
  def view_template
    render Components::Kit::Modal.new(
      id: "evidence-modal-overlay", title: "Feedback / evidence", size: :"3xl", header: false, standalone: false,
      dirty_guard: "Discard your unsaved feedback / evidence?",
      panel_data: { controller: "submit-fallback frame-error",
                    submit_fallback_text_value: "Couldn't save your feedback — check your connection and try again. Your text is still here.",
                    action: "turbo:before-fetch-response->submit-fallback#beforeFetchResponse " \
                            "turbo:submit-start->submit-fallback#submitStart " \
                            "turbo:submit-end->submit-fallback#submitEnd " \
                            "modal:open@window->submit-fallback#submitStart" }
    ) do |modal|
      modal.body do
        render Components::Shared::SubmitFallbackMessage.new(classes: "mx-5 mt-4")
        turbo_frame_tag("evidence-modal", loading: "lazy",
                        data: { evidence_modal_target: "frame", frame_error_target: "frame" }) do
          div(class: "p-6 text-sm text-muted") { "Loading…" }
        end
        render Components::Shared::FrameLoadError.new(
          id: "evidence-modal-error", subject: "the form", closeable: true
        )
      end
    end
  end
end

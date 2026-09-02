# frozen_string_literal: true

# The shared modal shell that hosts the unified evidence form. A bare
# overlay/panel (driven by the `modal` controller) wrapping the lazy
# `#evidence-modal` turbo-frame (driven by `evidence-modal#load`). A trigger
# sets the frame `src` and opens the overlay; the server renders the form.
#
# The frame's inline fallback is a "Loading…" placeholder. When the frame's
# GET fails — the network drops, the response carries no matching frame, or it
# isn't HTML at all (a proxy's text/plain 502, which Turbo discards in total
# silence) — that placeholder stands forever: a modal stuck on "Loading…" with
# no error and no way forward (audit issue #328). The error state below is
# rendered hidden and revealed by `evidence-modal#loadFailed`, giving the
# failure a voice, a Retry, and — since the form's own ×/Cancel went down with
# the hidden frame — a way out.
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
                          "turbo:before-fetch-response->evidence-modal#responseReceived " \
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
  # reveals it (in place of the "Loading…" placeholder). `role="alert"` so the
  # failure is announced, not only seen, and `tabindex="-1"` so the controller
  # can move focus here — the Retry the user just pressed is inside the frame
  # we hide, and focus would otherwise fall out of the dialog to <body>.
  #
  # Two ways forward, because hiding the frame also hides the form's own
  # ×/Cancel: Retry re-fetches, Close dismisses. The copy stays failure-
  # agnostic — the same state covers a dropped connection, a 500, and an
  # expired session, so "check your connection" would misdirect two of three.
  # @return [void]
  def load_error
    div(id: "evidence-modal-error", role: "alert", hidden: true, tabindex: "-1",
        class: "p-6 space-y-3", data: { evidence_modal_target: "error" }) do
      p(class: Components::Kit::SubmitFallbackMessage::PANEL_CLASSES) do
        "Couldn't load the form. Try again — if it keeps failing, close this and reload the page."
      end
      div(class: "flex gap-2") do
        button(type: "button", data: { action: "evidence-modal#retry" },
               class: Views::Evidence::ModalForm::SECONDARY_BTN) { "Retry" }
        button(type: "button", data: { action: "modal#close" },
               class: Views::Evidence::ModalForm::SECONDARY_BTN) { "Close" }
      end
    end
  end
end

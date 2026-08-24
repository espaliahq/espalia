// Prefills the shared reject-suggestion modal from the feed entry's Reject
// button (or, later, the matrix grid's reject affordance).
//
// On the window `modal:open` event it self-gates on `rejectSuggestionId`,
// points the form at that suggestion's reject endpoint (built from a path
// template with the id substituted), fills the "Reject «entity»" title and the
// proposed-value preview, and clears any prior reason. On a successful submit
// it dispatches `suggestion:resolved` so the matrix refreshes; the modal closes
// itself (modal#submitted) and the feed reloads via the activity broadcast.
//
// Usage:
//   <form data-controller="reject-suggestion-form"
//         data-reject-suggestion-form-action-template-value="/frameworks/F/suggestions/__SID__/reject"
//         data-action="turbo:submit-end->modal#submitted
//                      turbo:submit-end->reject-suggestion-form#submitted">
//     <span     data-reject-suggestion-form-target="title"></span>
//     <p        data-reject-suggestion-form-target="preview"></p>
//     <textarea data-reject-suggestion-form-target="reason"></textarea>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["title", "preview", "reason"]
  static values = { actionTemplate: String }

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  submitted(event) {
    if (event.detail?.success) {
      // The detail lets the rejected entry's suggestion-action controller
      // swap to its "✓ Rejected" state immediately (before the feed reload).
      window.dispatchEvent(new CustomEvent("suggestion:resolved", {
        detail: { suggestionId: this._suggestionId, outcome: "rejected" }
      }))
    }
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to reject triggers (other modals share the modal:open bus).
    if (data.rejectSuggestionId === undefined) return

    this._suggestionId = data.rejectSuggestionId
    this.element.action = this.actionTemplateValue.replace("__SID__", data.rejectSuggestionId)

    if (this.hasTitleTarget) {
      this.titleTarget.textContent = data.rejectEntityLabel || "suggestion"
    }
    if (this.hasPreviewTarget) {
      this.previewTarget.textContent = data.rejectPreview || ""
      this.previewTarget.classList.toggle("hidden", !data.rejectPreview)
    }
    if (this.hasReasonTarget) this.reasonTarget.value = ""
  }
}

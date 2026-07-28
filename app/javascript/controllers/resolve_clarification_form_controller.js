// Prefills the shared resolve-clarification modal from a "Resolve…" trigger
// (feed entry or pane suggestion card).
//
// On the window `modal:open` event it self-gates on `resolveClarificationId`,
// points the form at that clarification's resolve endpoint (built from a path
// template with the id substituted), fills the question preview, and clears
// any prior note. On a successful submit it dispatches `suggestion:resolved`
// so the matrix refreshes; the modal closes itself (modal#submitted) and the
// feed reloads via the activity broadcast.
//
// Usage:
//   <form data-controller="resolve-clarification-form"
//         data-resolve-clarification-form-action-template-value="/frameworks/F/suggestions/__SID__/resolve"
//         data-action="turbo:submit-end->modal#submitted
//                      turbo:submit-end->resolve-clarification-form#submitted">
//     <p        data-resolve-clarification-form-target="question"></p>
//     <textarea data-resolve-clarification-form-target="note"></textarea>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["question", "note"]
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
      window.dispatchEvent(new CustomEvent("suggestion:resolved"))
    }
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to resolve triggers (other modals share the modal:open bus).
    if (data.resolveClarificationId === undefined) return

    this.element.action = this.actionTemplateValue.replace("__SID__", data.resolveClarificationId)

    if (this.hasQuestionTarget) {
      this.questionTarget.textContent = data.resolveQuestionPreview
        ? `“${data.resolveQuestionPreview}”`
        : ""
      this.questionTarget.classList.toggle("hidden", !data.resolveQuestionPreview)
    }
    if (this.hasNoteTarget) this.noteTarget.value = ""
  }
}

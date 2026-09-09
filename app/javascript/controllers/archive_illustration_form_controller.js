// Prefills the shared archive-illustration modal from the illustration kebab
// that opened it. On the window `modal:open` event (dispatched by the modal
// controller with the trigger's dataset), it copies the illustration id and a
// short excerpt of its text into the form.
//
// This modal replaced the menu's `data-turbo-confirm` inline form — a native
// confirm() the user couldn't theme, couldn't give a reason to, and that the
// system suite could only drive through the flake-prone auto_confirm path.
//
// Usage:
//   <form data-controller="archive-illustration-form">
//     <input data-archive-illustration-form-target="illustrationId">
//     <span  data-archive-illustration-form-target="title"></span>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["illustrationId", "title", "reason"]

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to illustration-archive triggers (others share the bus).
    if (data.archiveIllustrationId === undefined) return

    this.illustrationIdTarget.value = data.archiveIllustrationId || ""
    if (this.hasTitleTarget) {
      this.titleTarget.textContent = data.archiveIllustrationLabel || "this example"
    }
    // The modal is shared across illustrations — a reason typed for a previous
    // one must not ride along to the next.
    if (this.hasReasonTarget) this.reasonTarget.value = ""
  }
}

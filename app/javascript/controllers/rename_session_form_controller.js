// Prefills the calibration list's shared "Rename session" dialog from the card
// kebab that opened it. On the window `modal:open` event (dispatched by the
// modal controller with the trigger's dataset) it points the form at that
// session and seeds the field with its current name.
//
// Usage:
//   <form data-controller="rename-session-form">
//     <input data-rename-session-form-target="name">
//   </form>
//   <button data-action="click->modal#open"
//           data-modal-target-id="rename-session-modal"
//           data-rename-session-action="/calibration_sessions/…/name"
//           data-rename-session-name="Engineering · H1">Rename…</button>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["name"]

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
    if (data.renameSessionAction === undefined) return

    this.element.action = data.renameSessionAction
    this.nameTarget.value = data.renameSessionName || ""
    // The modal focuses the first field; selecting the name makes "type a new
    // one" a single gesture.
    requestAnimationFrame(() => this.nameTarget.select())
  }
}

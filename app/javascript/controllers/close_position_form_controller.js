// Fills the scenario map's "Close position" form from the position's Close…
// item: where the form posts, the position's name, and who is in it, which
// the dialog names only when someone is.
//
// Usage:
//   <form data-controller="close-position-form">…</form>
//   <button data-action="click->modal#open" data-modal-target-id="close-position-modal"
//           data-close-action="/planning/…/positions/…" data-close-name="Backfill: Designer"
//           data-close-occupants="Ada Quill and Ben Ode">Close…</button>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["name", "occupants", "occupantNames"]

  connect() {
    super.connect()
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
    super.disconnect()
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    if (data.closeAction === undefined || !this.element.closest(`#${CSS.escape(data.modalTargetId || "")}`)) return

    this.element.action = data.closeAction
    this.nameTarget.textContent = data.closeName || ""
    this.occupantNamesTarget.textContent = data.closeOccupants || ""
    this.occupantsTarget.hidden = !data.closeOccupants
  }
}

// Prefills a shared "Rename" dialog from the control that opened it. On the
// window `modal:open` event, dispatched with the trigger's dataset, the form
// inside the opened dialog points itself at the trigger's URL and seeds the
// field with the current name, and an optional description field with
// `data-rename-description`.
//
// Usage:
//   <div id="rename-session-modal">
//     <form data-controller="rename-form">
//       <input data-rename-form-target="name">
//     </form>
//   </div>
//   <button data-action="click->modal#open"
//           data-modal-target-id="rename-session-modal"
//           data-rename-action="/calibration_sessions/…/name"
//           data-rename-name="Engineering · H1">Rename…</button>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["name", "description"]

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
    if (data.renameAction === undefined || !this.element.closest(`#${CSS.escape(data.modalTargetId || "")}`)) return

    this.element.action = data.renameAction
    this.#seed(this.nameTarget, data.renameName)
    if (this.hasDescriptionTarget) this.#seed(this.descriptionTarget, data.renameDescription)
    // The modal focuses the first field; selecting the name makes "type a new
    // one" a single gesture.
    requestAnimationFrame(() => this.nameTarget.select())
  }

  // The default too, so the modal's dirty guard asks only about text typed
  // since the dialog opened.
  #seed(field, value) {
    field.defaultValue = value || ""
    field.value = value || ""
  }
}

// Fills one of the scenario map's move dialogs from the button that opened
// it: "Move" for a person, "Move position" for a position. On the window
// `modal:open` event it points the form at what moves, and picks the
// destination: where a drag dropped (`data-move-to`), or where it is now. In
// the person dialog, moving to Unassigned hides the allocation and role, which
// a place there doesn't have; the position dialog has neither.
//
// Usage:
//   <form data-controller="move-form" data-move-form-unassigned-value="unassigned">…</form>
//   <button data-action="click->modal#open" data-modal-target-id="move-person-modal"
//           data-move-action="/planning/…/assignments/…" data-move-name="Ada Quill"
//           data-move-from="<unit id>" data-move-allocation="60">Move…</button>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["name", "from", "fromPosition", "to", "allocation", "role", "placeFields"]
  static values = { unassigned: String }

  connect() {
    super.connect()
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
    super.disconnect()
  }

  sync() {
    if (!this.hasPlaceFieldsTarget) return

    const leaving = this.toTarget.value === this.unassignedValue
    this.placeFieldsTarget.hidden = leaving
    this.allocationTarget.disabled = leaving
    this.roleTarget.disabled = leaving
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    if (data.moveAction === undefined || !this.element.closest(`#${CSS.escape(data.modalTargetId || "")}`)) return

    this.element.action = data.moveAction
    this.nameTarget.textContent = data.moveName || ""
    this.toTarget.value = data.moveTo || data.moveFrom || ""
    if (this.hasFromTarget) this.fromTarget.value = data.moveFrom || ""
    if (this.hasFromPositionTarget) this.fromPositionTarget.value = data.moveFromPosition || ""
    if (this.hasAllocationTarget) this.allocationTarget.value = data.moveAllocation || "100"
    if (this.hasRoleTarget) this.roleTarget.value = data.moveRole || ""
    this.sync()
  }
}

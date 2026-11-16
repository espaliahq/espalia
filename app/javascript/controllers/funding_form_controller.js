// Fills the Budget tab's funding dialog from the "Funding…" button that
// opened it: points both forms at the position, puts each line's current part
// in its field, and offers Clear only when the scenario sets the funding.
//
// Usage:
//   <div data-controller="funding-form">…</div>
//   <button data-action="click->modal#open" data-modal-target-id="funding-modal"
//           data-funding-action="/planning/…/fundings/…" data-funding-name="Engineer II"
//           data-funding-draws="<line id>=50,<line id>=50" data-funding-set="true">Funding…</button>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["name", "set", "clear", "part"]

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
    if (data.fundingAction === undefined || !this.element.closest(`#${CSS.escape(data.modalTargetId || "")}`)) return

    this.setTarget.action = data.fundingAction
    this.clearTarget.action = data.fundingAction
    this.clearTarget.hidden = data.fundingSet !== "true"
    this.nameTarget.textContent = data.fundingName || ""
    const parts = Object.fromEntries((data.fundingDraws || "").split(",").filter(Boolean).map((draw) => draw.split("=")))
    this.partTargets.forEach((input) => { input.value = parts[input.dataset.lineId] || "" })
  }
}

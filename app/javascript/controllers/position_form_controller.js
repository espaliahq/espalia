// Fills the scenario map's "Open a position" or "Edit position" form from
// the button that opened its dialog. On the window `modal:open` event it
// points the form at the button's `data-position-action` and sets each field
// from `data-position-<field>`. The edit form also keeps each value as
// opened in `original[…]`, so the server saves only what changed.
//
// Usage:
//   <form data-controller="position-form" data-position-form-mode-value="edit">…</form>
//   <button data-action="click->modal#open" data-modal-target-id="edit-position-modal"
//           data-position-action="/planning/…/positions/…" data-position-name="Backfill: Designer"
//           data-position-unit-id="…" data-position-level-id="…" data-position-fte="1"
//           data-position-basis="backfill" data-position-cost-centre="">Edit…</button>

import BaseController from "controllers/base_controller"

const FIELDS = { unit_id: "positionUnitId", level_id: "positionLevelId", fte: "positionFte", basis: "positionBasis", cost_centre: "positionCostCentre" }
const DEFAULTS = { fte: "1", basis: "new" }

export default class extends BaseController {
  static targets = ["name", "unit_id", "level_id", "fte", "basis", "cost_centre", "original"]
  static values = { mode: String }

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
    if (data.positionAction === undefined || !this.element.closest(`#${CSS.escape(data.modalTargetId || "")}`)) return

    this.element.action = data.positionAction
    this.element.querySelector("[role=alert]")?.remove()
    this.nameTarget.textContent = data.positionName || ""
    for (const [field, key] of Object.entries(FIELDS)) {
      const value = data[key] ?? DEFAULTS[field] ?? ""
      this.#set(field, value)
      const original = this.originalTargets.find((input) => input.dataset.field === field)
      if (original) original.value = value
    }
  }

  #set(field, value) {
    if (field === "basis") {
      this.basisTargets.forEach((radio) => { radio.checked = radio.value === (value || DEFAULTS.basis) })
    } else if (this.targets.has(field)) {
      this.targets.find(field).value = value
    }
  }
}

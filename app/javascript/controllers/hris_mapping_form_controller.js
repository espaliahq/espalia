// Prefills the shared HRIS mapping modal from the trigger that opened it, and
// limits the level choices to the chosen role's levels (#436).
//
// On the window `modal:open` event it self-gates on the modal id, then reads
// the trigger's `data-hris-mapping-title / -role / -level`. A title arrives
// locked: editing a mapping moves that title, it doesn't rename it — "Add
// mapping" sends a blank title and leaves the field editable.
//
// Usage:
//   <form data-controller="hris-mapping-form"
//         data-hris-mapping-form-modal-id-value="hris-mapping-modal"
//         data-hris-mapping-form-levels-value='{"EM":[3,4]}'>
//     <input data-hris-mapping-form-target="title">
//     <select data-hris-mapping-form-target="role"
//             data-action="change->hris-mapping-form#roleChanged">…</select>
//     <select data-hris-mapping-form-target="level">…</select>
//   </form>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["title", "role", "level"]
  static values = { levels: Object, modalId: String }

  connect() {
    super.connect()
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
    super.disconnect()
  }

  roleChanged() {
    const allowed = this.levelsValue[this.roleTarget.value] || []

    for (const option of this.levelTarget.options) {
      if (option.value === "") continue
      const offered = allowed.includes(Number(option.value))
      option.hidden = !offered
      option.disabled = !offered
    }
    if (this.levelTarget.selectedOptions[0]?.disabled) this.levelTarget.value = ""
  }

  // private

  #onOpen(event) {
    if (event.detail?.id !== this.modalIdValue) return
    const data = event.detail.dataset || {}

    const title = data.hrisMappingTitle || ""
    this.titleTarget.value = title
    this.titleTarget.readOnly = title !== ""
    this.roleTarget.value = data.hrisMappingRole || ""
    this.levelTarget.value = data.hrisMappingLevel || ""
    this.roleChanged()
  }
}

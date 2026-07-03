// Prefills the shared add-role modal from a family's "+ Add role" trigger.
//
// On the window `modal:open` event it self-gates on `addRoleFamilyId`, sets
// the hidden family id, shows the family name in the context line, clears the
// name/code fields, and resets the track select to IC. The current role
// selection is appended at submit time by the companion `tree-scope-fields`
// controller on the same form.
//
// Usage:
//   <form data-controller="add-role-form tree-scope-fields"
//         data-turbo-frame="role-tree-families"
//         data-action="turbo:submit-end->modal#submitted">
//     <input type="hidden" data-add-role-form-target="familyId">
//     <span data-add-role-form-target="familyName"></span>
//     <input data-add-role-form-target="name">
//     <input data-add-role-form-target="code">
//     <select data-add-role-form-target="track">…</select>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["familyId", "familyName", "name", "code", "track"]

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
    // Only respond to "+ Add role" triggers (others share the modal:open bus).
    if (data.addRoleFamilyId === undefined) return

    if (this.hasFamilyIdTarget) this.familyIdTarget.value = data.addRoleFamilyId
    if (this.hasFamilyNameTarget) this.familyNameTarget.textContent = data.addRoleFamilyName || ""
    if (this.hasNameTarget) this.nameTarget.value = ""
    if (this.hasCodeTarget) this.codeTarget.value = ""
    // The select keeps its last value across opens — reset so a "Management"
    // pick for one family can't silently carry into the next.
    if (this.hasTrackTarget) this.trackTarget.value = "ic"
  }
}

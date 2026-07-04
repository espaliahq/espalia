// Prefills the shared add-level modal from a role row's "+ level" trigger and
// validates the ordinal against the role's existing levels as the user types.
//
// On the window `modal:open` event it self-gates on `addLevelRoleId`, sets the
// hidden role id, shows the role name in the context line, prefills the
// ordinal with the role's next free ordinal, stores the role's taken ordinals
// (draft levels included — computed server-side onto the trigger), and clears
// title/code/is_entry. Typing a taken ordinal shows an inline error
// immediately and submit is blocked — the server round-trip for the edit page
// is far too heavy (multi-second) to be the first line of feedback. The same
// rule is still enforced server-side (Operation) and in the aggregate.
//
// Usage:
//   <form data-controller="add-level-form tree-scope-fields"
//         data-action="submit->add-level-form#validate turbo:submit-end->modal#submitted">
//     <input type="hidden" data-add-level-form-target="roleId">
//     <span data-add-level-form-target="roleName"></span>
//     <input type="number" data-add-level-form-target="ordinal"
//            data-action="input->add-level-form#ordinalChanged">
//     <p data-add-level-form-target="ordinalError" class="hidden"></p>
//     <input data-add-level-form-target="title">
//     <input data-add-level-form-target="code">
//     <input type="checkbox" data-add-level-form-target="isEntry">
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["roleId", "roleName", "ordinal", "ordinalError", "title", "code", "isEntry"]

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    this._takenOrdinals = new Set()
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  // Re-check as the user types so the error appears/clears immediately.
  ordinalChanged() {
    this.#applyOrdinalValidity()
  }

  // Blocks the submit when the ordinal is taken — the inline error is already
  // visible from ordinalChanged; this is the belt for a straight-to-submit.
  validate(event) {
    if (this.#applyOrdinalValidity()) return

    event.preventDefault()
    if (this.hasOrdinalTarget) this.ordinalTarget.focus()
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to "+ level" triggers (others share the modal:open bus).
    if (data.addLevelRoleId === undefined) return

    this._takenOrdinals = new Set(
      (data.addLevelTakenOrdinals || "").split(",").filter(Boolean).map(Number)
    )

    if (this.hasRoleIdTarget) this.roleIdTarget.value = data.addLevelRoleId
    if (this.hasRoleNameTarget) this.roleNameTarget.textContent = data.addLevelRoleName || ""
    if (this.hasOrdinalTarget) this.ordinalTarget.value = data.addLevelNextOrdinal || ""
    if (this.hasTitleTarget) this.titleTarget.value = ""
    if (this.hasCodeTarget) this.codeTarget.value = ""
    if (this.hasIsEntryTarget) this.isEntryTarget.checked = false
    this.#applyOrdinalValidity()
  }

  // Shows/hides the inline error for the current ordinal value.
  // @returns {boolean} whether the ordinal is valid (free or blank)
  #applyOrdinalValidity() {
    const value = this.hasOrdinalTarget ? parseInt(this.ordinalTarget.value, 10) : NaN
    const taken = !Number.isNaN(value) && this._takenOrdinals.has(value)

    if (this.hasOrdinalErrorTarget) {
      this.ordinalErrorTarget.textContent = taken
        ? `This role already has a level ${value} — pick a free level number.`
        : ""
      // Inline style, not the `hidden` class — a competing display utility on
      // the element would tie it on specificity (assessments.md Lesson 17).
      this.ordinalErrorTarget.style.display = taken ? "" : "none"
      this.ordinalErrorTarget.classList.remove("hidden")
    }
    return !taken
  }
}

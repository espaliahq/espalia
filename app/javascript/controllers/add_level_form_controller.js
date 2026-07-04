// Prefills the shared add-level modal from a role row's "+ level" trigger.
//
// On the window `modal:open` event it self-gates on `addLevelRoleId`, sets the
// hidden role id, shows the role name in the context line, prefills the
// ordinal with the role's next free ordinal (computed server-side onto the
// trigger), and clears title/code/is_entry. The current role selection is
// appended at submit time by the companion `tree-scope-fields` controller.
//
// Usage:
//   <form data-controller="add-level-form tree-scope-fields"
//         data-action="turbo:submit-end->modal#submitted">
//     <input type="hidden" data-add-level-form-target="roleId">
//     <span data-add-level-form-target="roleName"></span>
//     <input type="number" data-add-level-form-target="ordinal">
//     <input data-add-level-form-target="title">
//     <input data-add-level-form-target="code">
//     <input type="checkbox" data-add-level-form-target="isEntry">
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["roleId", "roleName", "ordinal", "title", "code", "isEntry"]

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
    // Only respond to "+ level" triggers (others share the modal:open bus).
    if (data.addLevelRoleId === undefined) return

    if (this.hasRoleIdTarget) this.roleIdTarget.value = data.addLevelRoleId
    if (this.hasRoleNameTarget) this.roleNameTarget.textContent = data.addLevelRoleName || ""
    if (this.hasOrdinalTarget) this.ordinalTarget.value = data.addLevelNextOrdinal || ""
    if (this.hasTitleTarget) this.titleTarget.value = ""
    if (this.hasCodeTarget) this.codeTarget.value = ""
    if (this.hasIsEntryTarget) this.isEntryTarget.checked = false
  }
}

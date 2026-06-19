// Prefills the shared "add capability" modal from the category's "+ Add
// capability" trigger that opened it. On the window `modal:open` event
// (dispatched by the modal controller with the trigger's dataset), it copies
// the category id into the hidden field and the category name into the title.
//
// Usage:
//   <form data-controller="add-capability-form" data-action="submit->add-capability-form#validateRoles">
//     <input data-add-capability-form-target="categoryId">
//     <span  data-add-capability-form-target="categoryName"></span>
//     <input type="checkbox" name="capability[role_ids][]" data-add-capability-form-target="role">
//     <p data-add-capability-form-target="rolesError" class="hidden"></p>
//   </form>
//
// On submit it blocks if no role is selected — a capability bound to no role is
// hidden from the role-filtered matrix, so at least one binding is required
// (the server enforces the same in AddCapability).

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["categoryId", "categoryName", "role", "rolesError"]

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  // Block submission unless at least one role is checked.
  validateRoles(event) {
    if (this.roleTargets.some((cb) => cb.checked)) {
      if (this.hasRolesErrorTarget) this.rolesErrorTarget.classList.add("hidden")
      return
    }
    event.preventDefault()
    if (this.hasRolesErrorTarget) this.rolesErrorTarget.classList.remove("hidden")
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to add-capability triggers (others share the modal:open bus).
    if (data.addCategoryId === undefined) return

    if (this.hasCategoryIdTarget) this.categoryIdTarget.value = data.addCategoryId || ""
    if (this.hasCategoryNameTarget) {
      this.categoryNameTarget.textContent = data.addCategoryName || "this category"
    }
    // Reset the error each time the modal opens.
    if (this.hasRolesErrorTarget) this.rolesErrorTarget.classList.add("hidden")
  }
}

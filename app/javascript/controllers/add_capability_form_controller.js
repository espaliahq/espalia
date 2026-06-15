// Prefills the shared "add capability" modal from the category's "+ Add
// capability" trigger that opened it. On the window `modal:open` event
// (dispatched by the modal controller with the trigger's dataset), it copies
// the category id into the hidden field and the category name into the title.
//
// Usage:
//   <form data-controller="add-capability-form">
//     <input data-add-capability-form-target="categoryId">
//     <span  data-add-capability-form-target="categoryName"></span>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["categoryId", "categoryName"]

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
    // Only respond to add-capability triggers (others share the modal:open bus).
    if (data.addCategoryId === undefined) return

    if (this.hasCategoryIdTarget) this.categoryIdTarget.value = data.addCategoryId || ""
    if (this.hasCategoryNameTarget) {
      this.categoryNameTarget.textContent = data.addCategoryName || "this category"
    }
  }
}

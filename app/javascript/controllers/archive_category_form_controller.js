// Prefills the shared archive-category modal from the category-header kebab that
// opened it. On the window `modal:open` event (dispatched by the modal
// controller with the trigger's dataset), it copies the category id/name into
// the form. Unlike archive-form (capabilities), there is no migration mapping.
//
// Usage:
//   <form data-controller="archive-category-form">
//     <input data-archive-category-form-target="categoryId">
//     <span  data-archive-category-form-target="title"></span>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["categoryId", "title", "reason"]

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
    // Only respond to archive-category-kebab triggers (others share the bus).
    if (data.archiveCategoryId === undefined) return

    this.categoryIdTarget.value = data.archiveCategoryId || ""
    if (this.hasTitleTarget) {
      this.titleTarget.textContent = data.archiveCategoryName || "this category"
    }
    // Clear any reason left over from a previous open (the modal is shared
    // across categories — a stale reason must not ride along to the next one).
    if (this.hasReasonTarget) this.reasonTarget.value = ""
  }
}

// Reorders the items of an explorer edit-mode list via ↑/↓ move buttons.
//
// Sits on the list container (e.g. the illustrations <ul> for one
// expectation × role). Items are the descendants carrying
// data-reorder-item-id, in DOM order; each item's move buttons declare
// data-action="reorder-list#moveUp" / "reorder-list#moveDown".
//
// A move POSTs a neighbour-relative reorder ({ entity id, target id,
// placement }) and, on success, moves the item's node in the DOM — no frame
// refresh, so the expanded row / scroll position are untouched. Server state
// is authoritative: a non-2xx (stale neighbour, revoked rights) leaves the
// DOM unchanged. Moving the first item up / last item down is a no-op.
//
// Usage:
//   <ul data-controller="reorder-list"
//       data-reorder-list-url-value="/frameworks/F/illustration_reorders"
//       data-reorder-list-param-name-value="illustration_id">
//     <turbo-frame data-reorder-item-id="UUID">
//       …<button data-action="reorder-list#moveUp">↑</button>…
//     </turbo-frame>
//   </ul>

import BaseController from "controllers/base_controller"
import { post } from "@rails/request.js"

export default class extends BaseController {
  static values = {
    url: String,
    paramName: String
  }

  moveUp(event) {
    this.#move(event, "before")
  }

  moveDown(event) {
    this.#move(event, "after")
  }

  // private

  async #move(event, placement) {
    event.preventDefault()
    event.stopPropagation()

    const item = event.currentTarget.closest("[data-reorder-item-id]")
    if (!item || this._inFlight) return

    const items = this.#items()
    const index = items.indexOf(item)
    const target = placement === "before" ? items[index - 1] : items[index + 1]
    if (!target) return // already first / last

    this._inFlight = true
    try {
      const response = await post(this.urlValue, {
        body: JSON.stringify({
          reorder: {
            [this.paramNameValue]: item.dataset.reorderItemId,
            target_id: target.dataset.reorderItemId,
            placement: placement
          }
        }),
        contentType: "application/json"
      })
      if (response.ok) {
        placement === "before" ? target.before(item) : target.after(item)
      }
    } finally {
      this._inFlight = false
    }
  }

  #items() {
    return Array.from(this.element.querySelectorAll("[data-reorder-item-id]"))
  }
}

// Posts a single neighbour-relative reorder move and refreshes the matrix.
//
// The counterpart to reorder_list_controller for entities whose DOM can't be
// moved in place (a category is a contiguous BLOCK of table rows; a
// capability is a compact row + its hidden expanded row). Instead of DOM
// surgery, a successful move dispatches the window `org-structure:updated`
// event the explorer layout already routes to matrix#refresh — the matrix
// re-renders with the new order and fresh neighbour ids on every affordance.
//
// Usage (one controller per move button):
//   <button data-controller="reorder-move"
//           data-reorder-move-url-value="/frameworks/F/category_reorders"
//           data-reorder-move-body-value='{"reorder":{"category_id":"C","target_id":"T","placement":"before"}}'
//           data-action="reorder-move#move">↑</button>

import BaseController from "controllers/base_controller"
import { post } from "@rails/request.js"

export default class extends BaseController {
  static values = {
    url: String,
    body: Object
  }

  async move(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this._inFlight) return

    this._inFlight = true
    try {
      const response = await post(this.urlValue, {
        body: JSON.stringify(this.bodyValue),
        contentType: "application/json"
      })
      if (response.ok) {
        window.dispatchEvent(new CustomEvent("org-structure:updated"))
      }
    } finally {
      this._inFlight = false
    }
  }
}

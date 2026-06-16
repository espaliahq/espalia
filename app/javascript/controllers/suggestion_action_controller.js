// Inline approve for an actionable framework activity-feed entry.
//
// Wraps the approve button on a pending-suggestion row. `approve` POSTs to the
// suggestion's approve endpoint (which returns a quiet 200); on success it
// dispatches a window `suggestion:resolved` event so the matrix controller
// refreshes the grid (clearing the now-applied inline diff). The feed itself
// reloads off the activity broadcast — no client work needed for that.
//
// Reject is NOT handled here: rejecting always opens the shared reject modal
// (reason optional) via the modal controller.
//
// Usage:
//   <div data-controller="suggestion-action"
//        data-suggestion-action-approve-url-value="/frameworks/F/suggestions/S/approve">
//     <button data-action="suggestion-action#approve">Approve</button>
//   </div>

import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"

export default class extends Controller {
  static values = { approveUrl: String }

  async approve(event) {
    event.preventDefault()
    const button = event.currentTarget
    if (button.disabled) return
    button.disabled = true

    const response = await post(this.approveUrlValue, { responseKind: "turbo-stream" })

    if (response.ok) {
      // Matrix refreshes for the acting user; the feed reloads via broadcast.
      window.dispatchEvent(new CustomEvent("suggestion:resolved"))
    } else {
      button.disabled = false
    }
  }
}

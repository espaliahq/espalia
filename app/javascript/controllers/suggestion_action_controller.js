// Inline approve for an actionable framework activity-feed entry.
//
// Wraps the action row on a pending-suggestion entry. `approve` POSTs to the
// suggestion's approve endpoint (`inline=1` → 204). Feedback is immediate and
// local: the button reads "Approving…" during the POST, and on success the
// action row swaps to a "✓ Approved" state in place — the broadcast-driven
// feed reload (1-2s later) then renders the canonical resolution entry. The
// window `suggestion:resolved` event (with the suggestion id in the detail)
// also lets the matrix refresh and lets a rejection landed via the shared
// modal resolve this row the same way.
//
// Reject is NOT handled here: rejecting always opens the shared reject modal
// (reason optional) via the modal controller.
//
// Also mounted directly on the grid kebabs' Approve menu items (no targets
// there — the label swap is the feedback and the matrix refresh re-renders
// the grid).
//
// Usage:
//   <div data-controller="suggestion-action"
//        data-suggestion-action-approve-url-value="/frameworks/F/suggestions/S/approve"
//        data-suggestion-action-suggestion-id-value="S"
//        data-action="suggestion:resolved@window->suggestion-action#onResolved">
//     <div data-suggestion-action-target="actions">
//       <button data-action="suggestion-action#approve">Approve</button>
//       ...reject trigger...
//     </div>
//     <p class="hidden" data-suggestion-action-target="resolved"></p>
//   </div>

import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"

export default class extends Controller {
  static targets = ["actions", "resolved"]
  static values = { approveUrl: String, suggestionId: String }

  async approve(event) {
    event.preventDefault()
    const button = event.currentTarget
    if (button.disabled) return
    button.disabled = true
    const originalLabel = button.textContent
    button.textContent = "Approving…"

    const response = await post(this.approveUrlValue, { responseKind: "turbo-stream" })

    if (response.ok) {
      this.#showResolved("✓ Approved")
      // Matrix refreshes for the acting user; the feed reloads via broadcast.
      // The detail lets other surfaces showing this suggestion resolve too.
      window.dispatchEvent(new CustomEvent("suggestion:resolved", {
        detail: { suggestionId: this.suggestionIdValue, outcome: "approved" }
      }))
    } else {
      button.disabled = false
      button.textContent = originalLabel
    }
  }

  // A resolution for THIS suggestion landed elsewhere (the reject modal, or
  // the same suggestion actioned on another surface) — mirror it locally so
  // the row doesn't sit actionable-looking until the feed reload.
  onResolved(event) {
    const { suggestionId, outcome } = event.detail || {}
    if (!suggestionId || suggestionId !== this.suggestionIdValue) return

    this.#showResolved(outcome === "rejected" ? "✓ Rejected" : "✓ Approved")
  }

  // private

  #showResolved(label) {
    // The grid kebab items mount this controller on a bare button — no
    // targets there; the matrix refresh is their feedback.
    if (!this.hasActionsTarget || !this.hasResolvedTarget) return

    this.actionsTarget.classList.add("hidden")
    this.resolvedTarget.textContent = label
    this.resolvedTarget.classList.remove("hidden")
  }
}

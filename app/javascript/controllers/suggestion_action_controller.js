// Inline approve for an actionable framework activity-feed entry.
//
// Wraps the action row on a pending-suggestion entry. `approve` POSTs to the
// suggestion's approve endpoint (`inline=1`). Feedback is immediate and
// local: the button reads "Approving…" during the POST, and on success the
// action row swaps to a "✓ Approved" state in place — the broadcast-driven
// feed reload (1-2s later) then renders the canonical resolution entry. The
// window `suggestion:resolved` event (with the suggestion id in the detail)
// also lets the matrix update and lets a rejection landed via the shared
// modal resolve this row the same way.
//
// The response is either a surgical Turbo Stream (request.js renders it —
// just the affected entity's frame swaps, `surgical: true` on the event) or
// a 204, in which case the matrix falls back to a full frame refresh.
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

    // request.js rejects (not resolves) on network failure and on 401 —
    // without the catch the button would sit disabled reading "Approving…"
    // forever with no retry path.
    let response
    try {
      response = await post(this.approveUrlValue, { responseKind: "turbo-stream" })
    } catch {
      response = null
    }

    if (response?.ok) {
      // Terminal label for the bare kebab mount (no targets there): stays
      // informative even if the follow-up matrix update fails, and never
      // re-enables a button whose suggestion is already approved.
      button.textContent = "✓ Approved"
      // A turbo-stream response is the surgical in-place update (request.js
      // already rendered it) — the matrix must NOT also do the multi-MB full
      // frame refresh. A 204 means the shape wasn't surgically addressable
      // and the full refresh remains the fallback.
      const surgical = (response.contentType || "").includes("turbo-stream")
      // The detail resolves every surface showing this suggestion in place —
      // including THIS row (the element listens for the event too), so the
      // resolved-marker swap has exactly one code path.
      window.dispatchEvent(new CustomEvent("suggestion:resolved", {
        detail: { suggestionId: this.suggestionIdValue, outcome: "approved", surgical }
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
    if (!this.hasActionsTarget || !this.hasResolvedTarget) {
      // The grid kebab items mount this controller on a bare button. With
      // surgical updates, a kebab OUTSIDE the swapped frame (row/cell kebabs)
      // survives the resolution — mark it terminal so a stale menu item can't
      // look re-approvable.
      const button = this.element.matches("button")
        ? this.element
        : this.element.querySelector("[data-action*='suggestion-action#approve']")
      if (button) {
        button.disabled = true
        button.textContent = label
      }
      return
    }

    this.actionsTarget.classList.add("hidden")
    this.resolvedTarget.textContent = label
    this.resolvedTarget.classList.remove("hidden")
  }
}

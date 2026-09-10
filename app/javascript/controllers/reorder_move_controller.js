// Posts a single neighbour-relative reorder move and repositions the moved
// node(s) in place.
//
// It used to dispatch `org-structure:updated` → matrix#refresh instead — a full
// re-fetch of the edit-mode matrix frame (~950 KB of HTML on the real me&u
// framework) for a move that changes the order of two table rows. That threw
// away every loaded expanded row and the scroll position on every click.
//
// Now the response is a Turbo Stream carrying only the toast (rendered
// automatically by @rails/request.js), and the controller moves the DOM:
//
// - `capability` — the compact `<tr>` plus its hidden expanded `<tr>`, which
//   must stay adjacent (the accordion pairs them by capability id).
// - `category` — the whole `<tbody>` group.
//
// The menu re-reads its neighbours from the DOM each time it opens, so the
// directions offered stay correct after an in-place move (see
// explorer_menu_controller's move builders).
//
// Usage (built by explorer-menu, one per open menu item):
//   <button data-controller="reorder-move"
//           data-reorder-move-url-value="/frameworks/F/category_reorders"
//           data-reorder-move-scope-value="category"
//           data-reorder-move-body-value='{"reorder":{"category_id":"C","target_id":"T","placement":"before"}}'
//           data-action="reorder-move#move">Move up</button>

import BaseController from "controllers/base_controller"
import { post } from "@rails/request.js"

export default class extends BaseController {
  static values = {
    url: String,
    body: Object,
    scope: { type: String, default: "capability" }
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
      // request.js renders the toast itself for BOTH outcomes — its perform()
      // auto-renders a turbo-stream response on `ok || unprocessableEntity` —
      // so rendering it again here would tear the toast down and restart its
      // dismiss timer. All that's left to do is move the node on success.
      if (response.ok) this.#applyMove()
    } catch (error) {
      // Network failure — leave the DOM showing server state; don't let the
      // rejection escape the fire-and-forget action.
      console.warn("reorder-move: move request failed", error)
    } finally {
      this._inFlight = false
    }
  }

  // private

  #applyMove() {
    const { target_id: targetId, placement } = this.bodyValue.reorder || {}
    if (!targetId || !placement) return

    const nodes = this.#movingNodes()
    const anchor = this.#anchor(targetId, placement)
    if (!nodes.length || !anchor) return

    // Place the first node relative to the anchor, then chain the rest after it
    // so a capability's compact row keeps its expanded row directly beneath it.
    const [first, ...rest] = nodes
    if (placement === "before") anchor.before(first)
    else anchor.after(first)

    rest.reduce((cursor, node) => {
      cursor.after(node)
      return node
    }, first)
  }

  #movingNodes() {
    const reorder = this.bodyValue.reorder || {}
    if (this.scopeValue === "category") {
      return [document.getElementById(`category-group-${reorder.category_id}`)].filter(Boolean)
    }

    return [
      document.getElementById(`capability-row-${reorder.capability_id}`),
      document.getElementById(`expanded-row-${reorder.capability_id}`)
    ].filter(Boolean)
  }

  // Where the moved node lands. Moving a capability DOWN has to clear the
  // target's expanded row too, or the pair straddles it.
  #anchor(targetId, placement) {
    if (this.scopeValue === "category") return document.getElementById(`category-group-${targetId}`)

    const row = document.getElementById(`capability-row-${targetId}`)
    if (placement === "before") return row

    return document.getElementById(`expanded-row-${targetId}`) || row
  }
}

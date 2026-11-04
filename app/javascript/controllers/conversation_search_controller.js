// Narrows the Feedback / Evidence conversation list to the people whose name
// matches what's typed. The list is already on the page, so it filters in
// place.
//
// Usage:
// <nav data-controller="conversation-search">
//   <input data-conversation-search-target="input" data-action="input->conversation-search#filter">
//   <li data-conversation-search-target="row" data-name="jordan lee">…</li>
//   <li data-conversation-search-target="empty" hidden>No one matches that name.</li>
// </nav>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["input", "row", "empty"]

  filter() {
    const query = this.inputTarget.value.trim().toLowerCase()
    let shown = 0
    this.rowTargets.forEach(row => {
      const match = query === "" || row.dataset.name.includes(query)
      row.hidden = !match
      if (match) shown += 1
    })
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0 || this.rowTargets.length === 0
  }
}

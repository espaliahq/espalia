// Client-side filter chips for the framework activity feed.
//
// Switches the visible entry groups (All / Suggestions / Edits / Structural /
// Lifecycle / Collaborators) by toggling a `data-hidden` attribute on each
// entry — no server round-trip. Entry navigation (clicking an anchored entry
// to drive the matrix) is handled by the ancestor `context-pane` controller,
// not here.
//
// Example markup:
//   <div data-controller="framework-activity">
//     <button data-framework-activity-target="filterChip"
//             data-framework-activity-filter-param="edits"
//             data-action="click->framework-activity#setFilter">Edits</button>
//     <li data-framework-activity-target="entry" data-kind-group="edits">…</li>
//   </div>

import BaseController from "controllers/base_controller"

const VALID_FILTERS = ["all", "suggestions", "edits", "structural", "lifecycle", "collaborators"]

export default class extends BaseController {
  static targets = ["entry", "filterChip"]

  connect() {
    super.connect()
    this.filter = "all"
  }

  setFilter(event) {
    const next = event.params.filter
    if (!VALID_FILTERS.includes(next)) return
    this.filter = next
    this.#paintFilterChips()
    this.#applyState()
  }

  // Re-apply the active filter to entries appended after a "Load older
  // activity" fetch. Those arrive server-rendered (unfiltered) via a Turbo
  // Stream append; without this they'd ignore the current chip selection.
  // Stimulus fires this as each new entry target connects.
  entryTargetConnected(entry) {
    this.#applyTo(entry)
  }

  // private

  #applyState() {
    this.entryTargets.forEach(entry => this.#applyTo(entry))
  }

  #applyTo(entry) {
    const filter = this.filter || "all"
    const visible = filter === "all" || entry.dataset.kindGroup === filter
    entry.dataset.hidden = visible ? "false" : "true"
  }

  #paintFilterChips() {
    this.filterChipTargets.forEach(chip => {
      const pressed = chip.dataset.frameworkActivityFilterParam === this.filter
      chip.setAttribute("aria-pressed", pressed ? "true" : "false")
    })
  }
}

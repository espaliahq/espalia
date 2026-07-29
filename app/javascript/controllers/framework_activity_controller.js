// Client-side filter chips for an activity feed.
//
// Switches the visible entry groups by toggling a `data-hidden` attribute on
// each entry — no server round-trip. Entry navigation (clicking an anchored
// entry to drive the matrix) is handled by the ancestor `context-pane`
// controller, not here.
//
// DOM-generic despite the name: the valid filter set is read from the chips
// themselves, so any feed rendered in the product's activity-panel form can
// use it with its own groups (the framework explorer's panel and the
// calibration session log do today). The name is kept because
// `framework-activity` also prefixes the explorer's element ids and its Turbo
// stream, and renaming only the controller would split that vocabulary.
//
// Example markup:
//   <div data-controller="framework-activity">
//     <button data-framework-activity-target="filterChip"
//             data-framework-activity-filter-param="edits"
//             data-action="click->framework-activity#setFilter">Edits</button>
//     <li data-framework-activity-target="entry" data-kind-group="edits">…</li>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["entry", "filterChip"]

  connect() {
    super.connect()
    this.filter = "all"
  }

  setFilter(event) {
    const next = event.params.filter
    if (!this.#validFilters.includes(next)) return
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

  get #validFilters() {
    return this.filterChipTargets.map(chip => chip.dataset.frameworkActivityFilterParam)
  }

  #paintFilterChips() {
    this.filterChipTargets.forEach(chip => {
      const pressed = chip.dataset.frameworkActivityFilterParam === this.filter
      chip.setAttribute("aria-pressed", pressed ? "true" : "false")
    })
  }
}

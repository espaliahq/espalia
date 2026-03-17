// Dropdown controller using stimulus-use composable behaviors.
//
// Example usage:
// <div data-controller="dropdown"
//      data-action="keydown.esc@window->dropdown#close">
//   <button data-action="dropdown#toggle"
//           data-dropdown-target="trigger">Menu</button>
//   <div data-dropdown-target="menu" class="hidden">
//     <!-- menu items -->
//   </div>
// </div>

import { Controller } from "@hotwired/stimulus"
import { useClickOutside, useTransition } from "stimulus-use"

export default class extends Controller {
  static targets = ["menu", "trigger"]

  connect() {
    useClickOutside(this)
    useTransition(this, { element: this.menuTarget })
  }

  toggle() {
    this._toggling = true
    this.toggleTransition()
    this.#updateAria()
    requestAnimationFrame(() => { this._toggling = false })
  }

  close() {
    this.leave()
    this.#updateAria()
  }

  clickOutside() {
    if (this._toggling) return
    this.leave()
    this.#updateAria()
  }

  // private

  #updateAria() {
    if (this.hasTriggerTarget) {
      const expanded = !this.menuTarget.classList.contains("hidden")
      this.triggerTarget.setAttribute("aria-expanded", expanded)
    }
  }
}

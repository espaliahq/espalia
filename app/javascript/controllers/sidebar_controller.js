// Toggles the sidebar drawer on mobile viewports.
// Clicking outside the open drawer closes it.
//
// Usage:
//   <div data-controller="sidebar">
//     <button data-action="sidebar#toggle">☰</button>
//     <aside data-sidebar-target="drawer" class="hidden ...">...</aside>
//   </div>

import { Controller } from "@hotwired/stimulus"
import { useClickOutside } from "stimulus-use"

export default class extends Controller {
  static targets = ["drawer"]

  connect() {
    this.drawerOpen = false
  }

  toggle() {
    if (this.drawerOpen) {
      this.#close()
    } else {
      this.#open()
    }
  }

  // Called by useClickOutside when clicking outside the drawer
  clickOutside(event) {
    if (!this.drawerOpen) return
    // Don't close if clicking the toggle button itself
    if (event.target.closest("[data-action*='sidebar#toggle']")) return

    this.#close()
  }

  // private

  #open() {
    this.drawerOpen = true
    this.drawerTarget.classList.remove("hidden")
    useClickOutside(this, { element: this.drawerTarget })
  }

  #close() {
    this.drawerOpen = false
    this.drawerTarget.classList.add("hidden")
  }
}

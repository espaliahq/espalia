// Toggles the sidebar drawer on mobile viewports.
// Opening moves focus to the first link; Escape or the close button closes it
// and hands focus back to the toggle. Clicking outside, or tabbing out, closes it.
//
// Usage:
//   <div data-controller="sidebar">
//     <button data-sidebar-target="toggle" data-action="sidebar#toggle">☰</button>
//     <aside data-sidebar-target="drawer" class="hidden ...">...</aside>
//   </div>

import BaseController from "controllers/base_controller"
import { useClickOutside } from "stimulus-use"

export default class extends BaseController {
  static targets = ["drawer", "toggle"]

  connect() {
    super.connect()
    this.drawerOpen = false
    useClickOutside(this, { element: this.drawerTarget })
  }

  toggle() {
    if (this.drawerOpen) {
      this.#close()
    } else {
      this.#open()
    }
  }

  dismiss() {
    this.#close({ returnFocus: true })
  }

  escape() {
    if (!this.drawerOpen) return

    this.#close({ returnFocus: true })
  }

  // The drawer overlays the page, so focus that leaves it would land on content behind it.
  focusOut(event) {
    if (!this.drawerOpen || !event.relatedTarget) return
    if (this.drawerTarget.contains(event.relatedTarget)) return
    // The toggle's own click closes it; closing here too would make that click reopen it.
    if (this.toggleTargets.includes(event.relatedTarget)) return

    this.#close()
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
    this.#setExpanded(true)
    const first = this.drawerTarget.querySelector("nav a") ?? this.drawerTarget.querySelector("button")
    first?.focus()
  }

  #close({ returnFocus = false } = {}) {
    this.drawerOpen = false
    this.drawerTarget.classList.add("hidden")
    this.#setExpanded(false)
    if (returnFocus && this.hasToggleTarget) this.toggleTarget.focus()
  }

  #setExpanded(expanded) {
    this.toggleTargets.forEach((toggle) => toggle.setAttribute("aria-expanded", String(expanded)))
  }
}

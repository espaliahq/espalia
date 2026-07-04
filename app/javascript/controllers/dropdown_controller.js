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
//
// With data-dropdown-fixed-value="true" the open menu is positioned against
// the viewport (position: fixed at the trigger's rect) instead of relying on
// CSS absolute positioning — so it can escape overflow-clipping ancestors
// like the role tree's scroll pane. The menu closes on any scroll while open
// in this mode (a fixed menu would otherwise detach from its trigger).

import BaseController from "controllers/base_controller"
import { useClickOutside, useTransition } from "stimulus-use"

export default class extends BaseController {
  static targets = ["menu", "trigger"]
  static values = { fixed: { type: Boolean, default: false } }

  connect() {
    super.connect()
    useClickOutside(this)
    useTransition(this, { element: this.menuTarget })
    this._onAnyScroll = this.#onAnyScroll.bind(this)
  }

  disconnect() {
    window.removeEventListener("scroll", this._onAnyScroll, true)
  }

  toggle() {
    this._toggling = true
    const opening = this.menuTarget.classList.contains("hidden")
    if (this.fixedValue && opening) this.#positionFixed()
    this.toggleTransition()
    if (this.fixedValue) {
      if (opening) {
        window.addEventListener("scroll", this._onAnyScroll, true)
        // Clamp once the menu has real dimensions: flip above the trigger
        // when there is no room below.
        requestAnimationFrame(() => this.#clampFixed())
      } else {
        window.removeEventListener("scroll", this._onAnyScroll, true)
      }
    }
    this.#updateAria()
    requestAnimationFrame(() => { this._toggling = false })
  }

  close() {
    this.leave()
    window.removeEventListener("scroll", this._onAnyScroll, true)
    this.#updateAria()
  }

  clickOutside() {
    if (this._toggling) return
    this.leave()
    window.removeEventListener("scroll", this._onAnyScroll, true)
    this.#updateAria()
  }

  // private

  // Capture-phase listener: any scroll (window or a nested pane) moves the
  // trigger out from under a fixed menu, so close rather than float loose.
  #onAnyScroll() {
    if (this.menuTarget.classList.contains("hidden")) return
    this.close()
  }

  #positionFixed() {
    const rect = this.triggerTarget.getBoundingClientRect()
    const menu = this.menuTarget
    const width = 224 // w-56; measured post-open clamp handles the rest
    menu.style.position = "fixed"
    menu.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - width - 8))}px`
    menu.style.top = `${rect.bottom + 4}px`
    menu.style.right = "auto"
    menu.style.marginTop = "0"
  }

  #clampFixed() {
    const menu = this.menuTarget
    if (menu.classList.contains("hidden")) return

    const rect = menu.getBoundingClientRect()
    if (rect.bottom > window.innerHeight - 8) {
      const trigger = this.triggerTarget.getBoundingClientRect()
      menu.style.top = `${Math.max(8, trigger.top - rect.height - 4)}px`
    }
  }

  #updateAria() {
    if (this.hasTriggerTarget) {
      const expanded = !this.menuTarget.classList.contains("hidden")
      this.triggerTarget.setAttribute("aria-expanded", expanded)
    }
  }
}

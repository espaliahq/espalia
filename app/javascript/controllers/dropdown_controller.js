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
// like the role tree's scroll pane. The menu closes on any scroll that moves
// its trigger while open in this mode (it would otherwise detach from it).

import BaseController from "controllers/base_controller"
import { useClickOutside, useTransition } from "stimulus-use"

export default class extends BaseController {
  static targets = ["menu", "trigger"]
  static values = {
    fixed: { type: Boolean, default: false },
    align: { type: String, default: "left" }
  }

  connect() {
    super.connect()
    useClickOutside(this)
    useTransition(this, { element: this.menuTarget })
    this._onAnyScroll = this.#onAnyScroll.bind(this)
    // A menu item that opens a modal leaves this menu open behind it — and the
    // menu (z-50) outranks the overlay (z-40), so it renders over the dialog it
    // just launched. Clicking the item isn't an "outside" click, so close here.
    this._onModalOpen = this.#onModalOpen.bind(this)
    window.addEventListener("modal:open", this._onModalOpen)
  }

  disconnect() {
    window.removeEventListener("scroll", this._onAnyScroll, true)
    window.removeEventListener("modal:open", this._onModalOpen)
    super.disconnect()
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
    this.#setExpanded(opening)
    requestAnimationFrame(() => { this._toggling = false })
  }

  close() {
    this.leave()
    window.removeEventListener("scroll", this._onAnyScroll, true)
    this.#setExpanded(false)
  }

  clickOutside() {
    if (this._toggling) return
    this.leave()
    window.removeEventListener("scroll", this._onAnyScroll, true)
    this.#setExpanded(false)
  }

  // private

  #onModalOpen() {
    if (this.menuTarget.classList.contains("hidden")) return

    this.close()
  }

  // Capture-phase listener: any scroll (window or a nested pane) moves the
  // trigger out from under a fixed menu, so close rather than float loose.
  // Scrolls INSIDE the menu are exempt — a tall panel scrolls its own
  // content (max-h + overflow on the panel) without dismissing itself.
  // A scroll's event fires a frame late, so one made just before the menu
  // opened (a tap that scrolls its trigger into view) arrives after it:
  // close only once the trigger has really moved from where the menu sits.
  #onAnyScroll(event) {
    if (this.menuTarget.classList.contains("hidden")) return
    if (event && this.menuTarget.contains(event.target)) return
    if (!this.#triggerMoved()) return
    this.close()
  }

  #triggerMoved() {
    const { top, left } = this.triggerTarget.getBoundingClientRect()
    return Math.abs(top - this._anchor.top) >= 1 || Math.abs(left - this._anchor.left) >= 1
  }

  #positionFixed() {
    const rect = this.triggerTarget.getBoundingClientRect()
    this._anchor = { top: rect.top, left: rect.left }
    const menu = this.menuTarget
    // Pre-open guess only — the menu is still hidden so it can't be
    // measured; #clampFixed re-clamps horizontally with the REAL width
    // once it has dimensions (a w-96 panel was overhanging the viewport
    // when this assumed every menu is w-56).
    const width = 224
    // Honour the component's align: left anchors the menu's left edge to the
    // trigger's left, right anchors its right edge to the trigger's right.
    const anchored = this.alignValue === "right" ? rect.right - width : rect.left
    menu.style.position = "fixed"
    menu.style.left = `${Math.max(8, Math.min(anchored, window.innerWidth - width - 8))}px`
    menu.style.top = `${rect.bottom + 4}px`
    menu.style.right = "auto"
    menu.style.marginTop = "0"
  }

  #clampFixed() {
    const menu = this.menuTarget
    if (menu.classList.contains("hidden")) return

    // Horizontal re-clamp with the menu's REAL width — #positionFixed ran
    // before the menu was visible and guessed w-56.
    const width = menu.offsetWidth
    const left = parseFloat(menu.style.left) || 0
    menu.style.left = `${Math.max(8, Math.min(left, window.innerWidth - width - 8))}px`

    const rect = menu.getBoundingClientRect()
    if (rect.bottom > window.innerHeight - 8) {
      const trigger = this.triggerTarget.getBoundingClientRect()
      const roomAbove = trigger.top - 8
      const roomBelow = window.innerHeight - trigger.bottom - 8
      if (roomAbove > roomBelow) {
        // Flip above — but never past the viewport top (a tall panel used
        // to slide under the page's sticky chrome); the panel's own
        // max-h/overflow absorbs what doesn't fit.
        menu.style.top = `${Math.max(8, trigger.top - rect.height - 4)}px`
        menu.style.maxHeight = `${roomAbove}px`
      } else {
        menu.style.maxHeight = `${roomBelow}px`
      }
    }
  }

  // Set from intent, not from the menu's `hidden` class: useTransition only
  // adds `hidden` once the leave transition ends, so reading it here left
  // aria-expanded "true" after every close.
  #setExpanded(expanded) {
    if (this.hasTriggerTarget) this.triggerTarget.setAttribute("aria-expanded", expanded)
  }
}

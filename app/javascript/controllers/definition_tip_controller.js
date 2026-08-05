// Shows a term's definition panel in the browser's TOP LAYER, so it can't be
// clipped by whatever the term happens to sit inside.
//
// The CSS-only version (group-hover / group-focus-within) worked everywhere
// except the one place it mattered most: the rater-tendency table scrolls
// horizontally, and a `overflow-x: auto` ancestor is a clipping container on
// BOTH axes — the spec gives you no way to keep one axis visible — so half
// of every definition was cut off at the card's edge. `showPopover()` escapes
// that entirely.
//
// Progressive: if the browser has no popover API, the element keeps its
// group-hover/group-focus-within classes and behaves as before.
//
// Example usage:
//   <span data-controller="definition-tip">
//     <button data-definition-tip-target="trigger" aria-describedby="x">Self-gap</button>
//     <span id="x" role="tooltip" data-definition-tip-target="panel" popover="manual">…</span>
//   </span>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["trigger", "panel"]

  connect() {
    super.connect()
    this.show = this.show.bind(this)
    this.hide = this.hide.bind(this)
    this.reposition = this.reposition.bind(this)

    if (!this.supported) return

    this.triggerTarget.addEventListener("mouseenter", this.show)
    this.triggerTarget.addEventListener("focus", this.show)
    this.triggerTarget.addEventListener("mouseleave", this.hide)
    this.triggerTarget.addEventListener("blur", this.hide)
    this.element.addEventListener("keydown", this.hide)
  }

  disconnect() {
    if (this.supported) {
      this.triggerTarget.removeEventListener("mouseenter", this.show)
      this.triggerTarget.removeEventListener("focus", this.show)
      this.triggerTarget.removeEventListener("mouseleave", this.hide)
      this.triggerTarget.removeEventListener("blur", this.hide)
      this.element.removeEventListener("keydown", this.hide)
      this.hide()
    }
    super.disconnect()
  }

  get supported() {
    return this.hasPanelTarget && this.hasTriggerTarget &&
      typeof this.panelTarget.showPopover === "function"
  }

  show() {
    if (this.panelTarget.matches(":popover-open")) return

    this.panelTarget.showPopover()
    this.reposition()
    // A scroll or resize moves the term out from under its panel; the top
    // layer doesn't follow, so close rather than leave it stranded.
    window.addEventListener("scroll", this.hide, { capture: true, once: true })
    window.addEventListener("resize", this.hide, { once: true })
  }

  hide(event) {
    if (event?.type === "keydown" && event.key !== "Escape") return
    if (!this.panelTarget.matches(":popover-open")) return

    this.panelTarget.hidePopover()
  }

  // Under the term, but nudged back inside the viewport on both axes: the
  // Carried column is the far-right one on a wide table, and a term in the
  // last rows of a long strip has no room below it — a definition that opens
  // off-screen is the same as no definition.
  reposition() {
    const anchor = this.triggerTarget.getBoundingClientRect()
    const panel = this.panelTarget.getBoundingClientRect()
    const margin = 8
    const gap = 4

    const left = Math.min(
      Math.max(margin, anchor.left),
      Math.max(margin, window.innerWidth - panel.width - margin)
    )

    // Prefer below; flip above when that would overflow and there is more
    // room up there. Clamp either way, so a panel taller than the viewport
    // still starts on screen.
    const below = anchor.bottom + gap
    const above = anchor.top - panel.height - gap
    const overflowsBelow = below + panel.height > window.innerHeight - margin
    const top = overflowsBelow && above >= margin ? above : below

    // The top layer is viewport-relative; the fallback styling is absolute.
    this.panelTarget.style.position = "fixed"
    this.panelTarget.style.left = `${left}px`
    this.panelTarget.style.top =
      `${Math.min(Math.max(margin, top), Math.max(margin, window.innerHeight - panel.height - margin))}px`
  }
}

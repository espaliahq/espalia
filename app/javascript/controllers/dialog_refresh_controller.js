/**
 * Keeps an open dialog's focus when a Turbo Stream or a frame reload re-renders its contents:
 * whatever had focus is found again in the new contents, by `data-refresh-focus` or its id.
 *
 * @example
 * <div data-controller="dialog-refresh" data-dialog-refresh-content-value="capability-map-content">
 *   <turbo-frame id="capability-map-content">
 *     <a data-refresh-focus="lane-3">lane</a>
 *   </turbo-frame>
 * </div>
 */

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static values = { content: String }

  #keepFocus = (event) => this.#refocusAfter(event)

  connect() {
    super.connect()
    document.addEventListener("turbo:before-stream-render", this.#keepFocus)
    document.addEventListener("turbo:before-frame-render", this.#keepFocus)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.#keepFocus)
    document.removeEventListener("turbo:before-frame-render", this.#keepFocus)
    super.disconnect()
  }

  #refocusAfter(event) {
    const target = event.type === "turbo:before-frame-render" ? event.target.id : event.target.getAttribute("target")
    if (!this.contentValue || target !== this.contentValue) return

    // Turbo renders a frame a repaint after this event, so focus is read when the replacement actually runs.
    const render = event.detail.render
    event.detail.render = async (...args) => {
      const before = document.activeElement
      const selector = this.#selectorFor(before)
      await render(...args)
      if (!selector || before.isConnected || !this.#focusDropped()) return

      const focused = this.element.querySelector(selector)
      focused?.focus({ preventScroll: true })
      if (focused) this.#revealSideways(focused)
    }
  }

  /** True when the replacement took focus with it and nothing else has claimed it since. */
  #focusDropped() {
    const active = document.activeElement
    return !active || active === document.body || !active.isConnected
  }

  /** A re-rendered strip starts scrolled to its start, so bring the focused item back into it without moving the dialog. */
  #revealSideways(element) {
    const strip = element.parentElement?.closest(".overflow-x-auto")
    if (!strip) return

    const item = element.getBoundingClientRect()
    const bounds = strip.getBoundingClientRect()
    if (item.right > bounds.right) strip.scrollLeft += Math.ceil(item.right - bounds.right)
    else if (item.left < bounds.left) strip.scrollLeft -= Math.ceil(bounds.left - item.left)
  }

  #selectorFor(focused) {
    if (!focused || !this.element.contains(focused)) return null

    const keyed = focused.closest("[data-refresh-focus]")
    if (keyed) return `[data-refresh-focus="${CSS.escape(keyed.dataset.refreshFocus)}"]`
    return focused.id ? `#${CSS.escape(focused.id)}` : null
  }
}

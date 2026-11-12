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

    const selector = this.#selectorFor(document.activeElement)
    if (!selector) return

    const render = event.detail.render
    event.detail.render = async (...args) => {
      await render(...args)
      this.element.querySelector(selector)?.focus({ preventScroll: true })
    }
  }

  #selectorFor(focused) {
    if (!focused || !this.element.contains(focused)) return null

    const keyed = focused.closest("[data-refresh-focus]")
    if (keyed) return `[data-refresh-focus="${CSS.escape(keyed.dataset.refreshFocus)}"]`
    return focused.id ? `#${CSS.escape(focused.id)}` : null
  }
}

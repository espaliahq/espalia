/**
 * Lights every element sharing a `data-capability-map-key` while one is pointed at or focused,
 * and keeps a focused spoke or lane focused when a Turbo Stream updates the content it sits in.
 *
 * @example
 * <div data-controller="capability-map"
 *      data-capability-map-content-value="capability-map-content"
 *      data-action="mouseover->capability-map#light mouseout->capability-map#dim
 *                   focusin->capability-map#light focusout->capability-map#dim">
 *   <div id="capability-map-content">
 *     <a data-capability-map-key="3" data-radar-spoke="3">spoke</a>
 *     <a data-capability-map-key="3" data-capability-lane="3">lane</a>
 *   </div>
 * </div>
 */

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static values = { content: String }

  #hovered = null
  #focused = null
  #keepFocus = (event) => this.#refocusAfter(event)

  connect() {
    super.connect()
    document.addEventListener("turbo:before-stream-render", this.#keepFocus)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.#keepFocus)
    super.disconnect()
  }

  light(event) {
    this.#track(event, true)
  }

  dim(event) {
    this.#track(event, false)
  }

  /** The update replaces the focused node, so focus its counterpart once the stream has rendered. */
  #refocusAfter(event) {
    if (!this.contentValue || event.target.getAttribute("target") !== this.contentValue) return

    const focused = document.activeElement?.closest?.("[data-radar-spoke], [data-capability-lane]")
    if (!focused || !this.element.contains(focused)) return

    const selector = focused.hasAttribute("data-radar-spoke")
      ? `[data-radar-spoke="${focused.dataset.radarSpoke}"]`
      : `[data-capability-lane="${focused.dataset.capabilityLane}"]`
    const render = event.detail.render
    event.detail.render = async (stream) => {
      await render(stream)
      this.element.querySelector(selector)?.focus({ preventScroll: true })
    }
  }

  /** Hover and focus are tracked apart, so the pointer leaving a focused spoke keeps it lit. */
  #track(event, on) {
    const key = event.target.closest?.("[data-capability-map-key]")?.dataset.capabilityMapKey
    if (!key) return

    const value = on ? key : null
    if (event.type.startsWith("focus")) this.#focused = value
    else this.#hovered = value

    this.element.querySelectorAll("[data-capability-map-key]").forEach((el) => {
      const hot = [ this.#hovered, this.#focused ].includes(el.dataset.capabilityMapKey)
      if (hot) el.dataset.hot = "true"
      else delete el.dataset.hot
    })
  }
}

/**
 * Lights every element sharing a `data-capability-map-key` while one is pointed at or focused.
 *
 * @example
 * <div data-controller="capability-map"
 *      data-action="mouseover->capability-map#light mouseout->capability-map#dim
 *                   focusin->capability-map#light focusout->capability-map#dim">
 *   <a data-capability-map-key="3">spoke</a>
 *   <a data-capability-map-key="3">lane</a>
 * </div>
 */

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  #hovered = null
  #focused = null

  light(event) {
    this.#track(event, true)
  }

  dim(event) {
    this.#track(event, false)
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

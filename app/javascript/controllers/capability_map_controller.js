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
  light(event) {
    this.#mark(event, true)
  }

  dim(event) {
    this.#mark(event, false)
  }

  #mark(event, on) {
    const key = event.target.closest?.("[data-capability-map-key]")?.dataset.capabilityMapKey
    if (!key) return

    this.element.querySelectorAll(`[data-capability-map-key="${key}"]`).forEach((el) => {
      if (on) el.dataset.hot = "true"
      else delete el.dataset.hot
    })
  }
}

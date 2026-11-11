/** Lights every element sharing a `data-capability-map-key` while one is pointed at or focused. */

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

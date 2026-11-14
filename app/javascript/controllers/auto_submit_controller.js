// Submits its form when a field changes, for a GET picker such as the plan
// map's scenario select on a phone. A noscript button covers no JavaScript.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  submit() {
    this.element.requestSubmit()
  }
}

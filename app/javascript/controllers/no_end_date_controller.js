// A step's Dates page: ticking "No end date" switches the end date off, so the
// form asks for no date it would ignore.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["date", "check"]

  connect() {
    super.connect()
    this.sync()
  }

  sync() {
    this.dateTarget.disabled = this.checkTarget.checked
  }
}

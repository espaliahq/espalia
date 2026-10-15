// Opens the unified evidence modal as the hub arrives, when the URL asks for
// it (`?give=1` from the Home card's "Give feedback" link). It clicks the same
// trigger a person would, so there is one open-and-load path, not two.
//
// Example usage:
// <div data-controller="evidence-hub" data-evidence-hub-auto-open-value="true">
//   <button data-evidence-hub-target="autoTrigger"
//           data-action="evidence-modal#load click->modal#open" …>Give feedback</button>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["autoTrigger"]
  static values = { autoOpen: Boolean }

  connect() {
    super.connect()
    if (!this.autoOpenValue || !this.hasAutoTriggerTarget) return

    // Next frame, so the modal and evidence-modal controllers on the wrapper
    // have connected and the click reaches both actions.
    requestAnimationFrame(() => this.autoTriggerTarget.click())
  }
}

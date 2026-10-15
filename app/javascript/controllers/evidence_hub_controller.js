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
    // A Turbo cache preview is replaced by the real render a moment later;
    // opening from it would fetch the form twice.
    if (document.documentElement.hasAttribute("data-turbo-preview")) return

    // The ask is consumed: a reload or Back must not reopen the modal.
    const url = new URL(window.location.href)
    url.searchParams.delete("give")
    url.searchParams.delete("draft")
    window.history.replaceState(window.history.state, "", url)

    // Next frame, so the modal and evidence-modal controllers on the wrapper
    // have connected and the click reaches both actions.
    requestAnimationFrame(() => this.autoTriggerTarget.click())
  }
}

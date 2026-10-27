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

const CONNECT_TIMEOUT_MS = 10000

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

    this.#clickOnceModalConnected(performance.now() + CONNECT_TIMEOUT_MS)
  }

  disconnect() {
    cancelAnimationFrame(this.pendingFrame)
    super.disconnect()
  }

  // Each controller registers when its own module loads, in no set order. A
  // click before the wrapper's modal and evidence-modal controllers connect
  // reaches neither action, and the modal never opens.
  #clickOnceModalConnected(deadline) {
    const connected = ["modal", "evidence-modal"].every(identifier =>
      this.application.getControllerForElementAndIdentifier(this.element, identifier))
    if (connected) {
      this.autoTriggerTarget.click()
    } else if (performance.now() > deadline) {
      console.error("evidence-hub: the modal controllers never connected, so the form was not opened")
    } else {
      this.pendingFrame = requestAnimationFrame(() => this.#clickOnceModalConnected(deadline))
    }
  }
}

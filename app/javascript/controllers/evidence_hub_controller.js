// Opens the unified evidence modal as the hub arrives, when the URL asks for
// it (`?give=1` from the Home card's "Give feedback" link). It clicks the same
// trigger a person would, so there is one open-and-load path, not two.
//
// It also follows links sent before the page had conversations
// (`/evidence#evidence-item-<id>` in a Slack message): when the anchor names a
// message that isn't on this page, it asks the server which thread holds it.
// The browser never sends the anchor, so only the page can do this.
//
// Example usage:
// <div data-controller="evidence-hub" data-evidence-hub-auto-open-value="true">
//   <button data-evidence-hub-target="autoTrigger"
//           data-action="evidence-modal#load click->modal#open" …>Give feedback</button>
// </div>

import BaseController from "controllers/base_controller"

const CONNECT_TIMEOUT_MS = 10000
const OLD_ANCHOR = /^#evidence-(item|request)-([0-9a-f-]{36})$/

export default class extends BaseController {
  static targets = ["autoTrigger"]
  static values = { autoOpen: Boolean }

  connect() {
    super.connect()
    if (this.#followOldAnchor()) return
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

  #followOldAnchor() {
    const match = window.location.hash.match(OLD_ANCHOR)
    if (!match || document.getElementById(window.location.hash.slice(1))) return false

    const place = new URL(window.location.href).searchParams.get("place")
    const query = place === "org" ? "?place=org" : ""
    window.Turbo.visit(`/evidence/${match[1]}s/${match[2]}${query}`, { action: "replace" })
    return true
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

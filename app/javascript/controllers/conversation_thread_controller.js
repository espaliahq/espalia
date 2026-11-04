// Opens a Feedback / Evidence conversation on its newest message, the way a
// messaging app does, unless the URL names a message (`#evidence-item-…`),
// which the browser has already scrolled to.
//
// On a wide screen the thread scrolls inside its own pane; on a phone it is
// the page, so a thread opened on its own URL scrolls the window to the
// composer, with the newest message just above it.
//
// Usage:
// <section data-controller="conversation-thread" data-conversation-thread-explicit-value="true">
//   <div data-conversation-thread-target="body">…messages…</div>
//   <div data-conversation-thread-target="composer">…</div>
// </section>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["body", "composer"]
  static values = { explicit: Boolean }

  connect() {
    super.connect()
    if (this.#namedMessage()) return

    this.pendingFrame = requestAnimationFrame(() => this.#showNewest())
  }

  disconnect() {
    cancelAnimationFrame(this.pendingFrame)
    super.disconnect()
  }

  #namedMessage() {
    const id = decodeURIComponent(window.location.hash.slice(1))
    return id !== "" && this.element.querySelector(`[id="${CSS.escape(id)}"]`) !== null
  }

  #showNewest() {
    if (!this.hasBodyTarget) return

    if (getComputedStyle(this.bodyTarget).overflowY === "auto") {
      this.bodyTarget.scrollTop = this.bodyTarget.scrollHeight
    } else if (this.explicitValue && this.hasComposerTarget) {
      this.composerTarget.scrollIntoView({ block: "end" })
    }
  }
}

// Reloads the navbar notification bell when a new in-app notification lands.
//
// Mirrors assessment_sync_controller's signal-element pattern: a per-user
// Turbo Stream replaces the hidden #notifications-sync-signal element; this
// controller observes that mutation and reloads the bell frame (re-fetching
// its `src`), so the unread badge updates live without a page reload.
//
// Usage (in the navbar, signed-in only):
//   <div data-controller="notifications-sync">
//     <%= turbo_stream_from current_user, :notifications %>
//     <div id="notifications-sync-signal" data-notifications-sync-target="signal" hidden></div>
//     <turbo-frame id="notification-bell" src="/notifications/bell" loading="lazy"></turbo-frame>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["signal"]

  connect() {
    super.connect()
    this.#observeSignal()
  }

  disconnect() {
    this._observer?.disconnect()
    super.disconnect()
  }

  // private

  #observeSignal() {
    if (!this.hasSignalTarget) return

    this._observer = new MutationObserver(() => this.#reloadFrames())
    // Turbo Stream replace swaps the signal element itself, so watch the parent.
    this._observer.observe(this.signalTarget.parentElement, {
      childList: true,
      subtree: false
    })
  }

  #reloadFrames() {
    // Reload by id rather than via a frame target so the frame's `src` and
    // attributes survive the Turbo Stream replace untouched.
    document.getElementById("notification-bell")?.reload()
  }
}

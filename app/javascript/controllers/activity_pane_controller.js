// Activity pane controller for the assessment view's right-hand sidebar.
//
// Owns the open/closed state of the activity pane (lg+ inline,
// below-lg fixed overlay), the persistence cookie
// (`assessment_activity_pane_open`), and the data-pane-state attribute
// the CSS keys off. Mirrors the framework-explorer's context_pane
// pattern and the panel controller's open/close lifecycle, but lives
// on the page wrapper so trigger buttons inside the matrix turbo-frame
// (cousins of the pane element) can drive the toggle via a single
// Stimulus action listener.
//
// Example markup on the page wrapper:
//   <div data-controller="activity-pane">
//     <button data-action="click->activity-pane#toggle">Activity</button>
//     ...
//     <aside id="assessment-activity-pane" data-activity-pane-target="pane">
//       <turbo-frame id="assessment-activity"></turbo-frame>
//     </aside>
//   </div>

import BaseController from "controllers/base_controller"

const COOKIE_NAME = "assessment_activity_pane_open"
const COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365

export default class extends BaseController {
  static targets = ["pane", "toggle"]

  connect() {
    super.connect()
    this.applyState(this.currentState())
  }

  toggle() {
    const next = this.currentState() === "open" ? "closed" : "open"
    this.writeCookie(next)
    this.applyState(next)
  }

  open() {
    this.writeCookie("open")
    this.applyState("open")
  }

  close() {
    this.writeCookie("closed")
    this.applyState("closed")
  }

  // private

  currentState() {
    const url = new URL(window.location.href)
    const fromUrl = url.searchParams.get("activity")
    if (fromUrl === "open" || fromUrl === "closed") return fromUrl

    const cookie = this.readCookie()
    if (cookie === "open" || cookie === "closed") return cookie

    return "closed"
  }

  applyState(state) {
    if (this.hasPaneTarget) {
      this.paneTarget.dataset.paneState = state
      this.paneTarget.classList.toggle("hidden", state === "closed")
    }
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", state === "open" ? "true" : "false")
    }
  }

  readCookie() {
    const match = document.cookie.match(new RegExp("(?:^|; )" + COOKIE_NAME + "=([^;]+)"))
    return match ? decodeURIComponent(match[1]) : null
  }

  writeCookie(value) {
    document.cookie =
      `${COOKIE_NAME}=${encodeURIComponent(value)}; ` +
      `path=/; max-age=${COOKIE_MAX_AGE_SECONDS}; SameSite=Lax`
  }
}

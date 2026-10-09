// Activity pane controller for the assessment view's right-hand sidebar.
//
// Owns the open/closed state of the activity pane (lg+ inline,
// below-lg fixed overlay), the persistence cookie
// (`assessment_activity_pane_open`), the `?activity=open|closed`
// URL param, and the data-pane-state attribute the CSS keys off.
// Uses stimulus-use's `useTransition` for slide+fade animations and
// `useClickOutside` (mobile only) so tapping the matrix dismisses the
// pane like the scoring sidebar does.
//
// Mirrors the framework-explorer's context_pane pattern (popstate
// re-hydration, no-pushState-on-connect) and the panel controller's
// open/close lifecycle, but lives on the page wrapper so trigger
// buttons inside the matrix turbo-frame (cousins of the pane element)
// can drive the toggle via a single Stimulus action listener.
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
import { useClickOutside, useTransition } from "stimulus-use"

const COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365
const MOBILE_BREAKPOINT = 1024
// Gap kept between the fitted pane's bottom and the viewport's, and the
// least height it is ever given.
const FIT_BOTTOM_GAP_PX = 16
const FIT_MIN_HEIGHT_PX = 160

export default class extends BaseController {
  static targets = ["pane", "toggle"]
  // Each surface keeps its own open/closed preference — a room that runs
  // the calibration log open shouldn't force the assessment sidebar open —
  // and its own first-visit default (a page whose point IS the feed opens
  // it; one where the feed is a companion doesn't).
  static values = {
    cookie: { type: String, default: "assessment_activity_pane_open" },
    defaultState: { type: String, default: "closed" },
    // lg+ only: cap the pane's height at what is left below its own top.
    // The pane is sticky under a header that grows, shrinks and scrolls
    // away, and until it sticks it sits lower than its sticky offset, so
    // no CSS height can keep its bottom (and the feed's last entries) on
    // screen in every position.
    fitViewport: { type: Boolean, default: false }
  }

  connect() {
    super.connect()
    const initialState = this.#computeInitialState()

    // Opacity-only fade — translating the pane off-screen during enter
    // would push it out of the viewport and delay the lazy turbo-frame's
    // IntersectionObserver fetch, racing with user clicks on filter chips
    // inside the pane the moment it opens.
    useTransition(this, {
      element: this.paneTarget,
      enterActive: "transition-opacity duration-150 ease-out",
      enterFrom: "opacity-0",
      enterTo: "opacity-100",
      leaveActive: "transition-opacity duration-100 ease-in",
      leaveFrom: "opacity-100",
      leaveTo: "opacity-0",
      hiddenClass: "hidden",
      transitioned: initialState === "open"
    })

    useClickOutside(this, { element: this.paneTarget })

    this.#applyMetadata(initialState)

    this.onPopState = () => this.#applyFromUrl()
    window.addEventListener("popstate", this.onPopState)

    if (this.fitViewportValue) this.#observeViewport()
  }

  disconnect() {
    window.removeEventListener("popstate", this.onPopState)
    this.#unobserveViewport()
    super.disconnect()
  }

  toggle() {
    const next = this.#visualState() === "open" ? "closed" : "open"
    this.#commit(next)
  }

  open() {
    this.#commit("open")
  }

  close() {
    this.#commit("closed")
  }

  // Fired by useClickOutside on every outside click. We only act on
  // mobile — on lg+ the pane sits inline alongside the matrix, so
  // clicking the matrix should not close it. Toggle-button clicks
  // are also "outside" the pane element; ignore them so tapping the
  // toggle to open doesn't immediately re-close.
  clickOutside(event) {
    if (window.innerWidth >= MOBILE_BREAKPOINT) return
    if (this.#visualState() !== "open") return
    if (event.target.closest("[data-action*='activity-pane#toggle']")) return
    this.#commit("closed")
  }

  // private

  // Reads URL → cookie → default. Used on connect AND on popstate.
  #computeInitialState() {
    const url = new URL(window.location.href)
    const fromUrl = url.searchParams.get("activity")
    if (fromUrl === "open" || fromUrl === "closed") return fromUrl

    const cookie = this.#readCookie()
    if (cookie === "open" || cookie === "closed") return cookie

    return this.defaultStateValue === "open" ? "open" : "closed"
  }

  #visualState() {
    if (!this.hasPaneTarget) return "closed"
    return this.paneTarget.dataset.paneState === "open" ? "open" : "closed"
  }

  // Animates to `state`, persists to cookie, and pushes URL — the
  // user-driven path. Initial connect and popstate intentionally bypass
  // this so we never pushState the cookie's value into history.
  #commit(state) {
    this.#animate(state)
    this.#applyMetadata(state)
    this.#writeCookie(state)
    this.#pushBrowserUrl(state)
  }

  // Browser back/forward changes the URL without remounting Stimulus
  // controllers. Re-hydrate state from URL and animate to match.
  #applyFromUrl() {
    const state = this.#computeInitialState()
    if (state === this.#visualState()) return
    this.#animate(state)
    this.#applyMetadata(state)
    this.#writeCookie(state)
  }

  #animate(state) {
    if (state === "open") {
      this.enter()
      this.#scheduleFit()
    } else {
      this.leave()
    }
  }

  #observeViewport() {
    this.onViewportChange = () => this.#scheduleFit()
    window.addEventListener("scroll", this.onViewportChange, { passive: true })
    window.addEventListener("resize", this.onViewportChange)
    // The header can change height without a scroll (a frame re-render).
    this.bodyResizeObserver = new ResizeObserver(this.onViewportChange)
    this.bodyResizeObserver.observe(document.body)
    this.#scheduleFit()
  }

  #unobserveViewport() {
    if (!this.onViewportChange) return
    window.removeEventListener("scroll", this.onViewportChange)
    window.removeEventListener("resize", this.onViewportChange)
    this.bodyResizeObserver.disconnect()
    if (this.fitFrame) cancelAnimationFrame(this.fitFrame)
    this.onViewportChange = null
  }

  #scheduleFit() {
    if (!this.fitViewportValue || this.fitFrame) return
    this.fitFrame = requestAnimationFrame(() => {
      this.fitFrame = null
      this.#fit()
    })
  }

  #fit() {
    if (!this.hasPaneTarget) return
    const pane = this.paneTarget
    if (window.innerWidth < MOBILE_BREAKPOINT || this.#visualState() !== "open") {
      pane.style.maxHeight = ""
      return
    }
    const room = window.innerHeight - pane.getBoundingClientRect().top - FIT_BOTTOM_GAP_PX
    pane.style.maxHeight = `${Math.max(FIT_MIN_HEIGHT_PX, Math.floor(room))}px`
  }

  #applyMetadata(state) {
    if (this.hasPaneTarget) this.paneTarget.dataset.paneState = state
    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", state === "open" ? "true" : "false")
    }
  }

  #pushBrowserUrl(state) {
    const url = new URL(window.location.href)
    url.searchParams.set("activity", state)
    if (url.toString() !== window.location.href) {
      window.history.pushState({}, "", url)
    }
  }

  #readCookie() {
    const match = document.cookie.match(new RegExp("(?:^|; )" + this.cookieValue + "=([^;]+)"))
    return match ? decodeURIComponent(match[1]) : null
  }

  #writeCookie(value) {
    document.cookie =
      `${this.cookieValue}=${encodeURIComponent(value)}; ` +
      `path=/; max-age=${COOKIE_MAX_AGE_SECONDS}; SameSite=Lax`
  }
}

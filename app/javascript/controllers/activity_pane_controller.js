// Activity pane controller for the assessment view's right-hand sidebar.
//
// Owns the open/closed state of the activity pane (lg+ inline,
// below-lg fixed overlay), the persistence cookie
// (`assessment_activity_pane_open`), the `?activity=open|closed`
// URL param (the key is a value; `Kit::SidePanel` sets its own), and the data-pane-state attribute the CSS keys off.
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
import { somethingElseIsOpen } from "controllers/overlay_guard"

const COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365
const MOBILE_BREAKPOINT = 1024
// Gap kept between the fitted pane's bottom and the viewport's.
const FIT_BOTTOM_GAP_PX = 16
// Marks the history entry the overlay pushed. Holds the URL key, so two
// panes on one page don't take each other's entries.
const HISTORY_KEY = "sidePanelOverlay"

export default class extends BaseController {
  static targets = ["pane", "toggle"]
  // Each surface keeps its own open/closed preference — a room that runs
  // the calibration log open shouldn't force the assessment sidebar open —
  // and its own first-visit default (a page whose point IS the feed opens
  // it; one where the feed is a companion doesn't).
  static values = {
    cookie: { type: String, default: "assessment_activity_pane_open" },
    defaultState: { type: String, default: "closed" },
    // The query parameter that carries the state, so two surfaces' links
    // don't open each other's pane.
    urlKey: { type: String, default: "activity" },
    // Below lg, a tap outside closes the pane. Off for a pane that stacks
    // under the page instead of overlaying it, where the tap is on the page.
    dismissOutside: { type: Boolean, default: true },
    // lg+ only: cap the pane's height at what is left below its own top.
    // The pane is sticky under a header that grows, shrinks and scrolls
    // away, and until it sticks it sits lower than its sticky offset, so
    // no CSS height can keep its bottom (and the feed's last entries) on
    // screen in every position.
    fitViewport: { type: Boolean, default: false },
    // Set by `Kit::SidePanel`. Beside the page the pane adds no history
    // entries; below lg its overlay acts as a screen of its own: Back and
    // Escape close it, and focus moves in. Off, each toggle pushes an entry,
    // as the calibration log panes still expect until they move onto the Kit.
    screen: { type: Boolean, default: false }
  }

  #leaving = false

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

    this.onPopState = (event) => this.#applyFromHistory(event.state)
    window.addEventListener("popstate", this.onPopState)
    this.onBeforeVisit = () => this.#stampOwnEntry()
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)

    this.narrowQuery = window.matchMedia(`(width < ${MOBILE_BREAKPOINT}px)`)
    this.onNarrowChange = () => this.#followBreakpoint()
    this.narrowQuery.addEventListener("change", this.onNarrowChange)

    if (this.fitViewportValue) this.#observeViewport()

    // A page that opens with the overlay up needs the entry Back closes it with.
    if (initialState === "open" && this.#actsAsScreen() && !this.#onOwnEntry()) {
      this.#recordInHistory("open", true)
    }
  }

  disconnect() {
    window.removeEventListener("popstate", this.onPopState)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    this.narrowQuery.removeEventListener("change", this.onNarrowChange)
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

  // Bound to Escape on the window, in the capture phase so it looks before a
  // menu's own Escape closes it. Only the overlay answers, and it gives way
  // to a modal or menu open on top, which Escape closes first.
  escape() {
    if (!this.#actsAsScreen() || this.#visualState() !== "open" || somethingElseIsOpen()) return
    this.#commit("closed")
  }

  // A toggle a frame re-renders arrives with the server's aria-expanded.
  toggleTargetConnected(toggle) {
    toggle.setAttribute("aria-expanded", this.#visualState() === "open" ? "true" : "false")
  }

  // Fired by useClickOutside on every outside click. We only act on
  // mobile — on lg+ the pane sits inline alongside the matrix, so
  // clicking the matrix should not close it. Toggle-button clicks
  // are also "outside" the pane element; ignore them so tapping the
  // toggle to open doesn't immediately re-close.
  clickOutside(event) {
    if (!this.dismissOutsideValue) return
    if (window.innerWidth >= MOBILE_BREAKPOINT) return
    if (this.#visualState() !== "open") return
    if (somethingElseIsOpen()) return
    if (event.target.closest("[data-action*='activity-pane#toggle']")) return
    this.#commit("closed")
  }

  // private

  // Reads URL → cookie → default. Used on connect AND on popstate.
  #computeInitialState() {
    const url = new URL(window.location.href)
    const fromUrl = url.searchParams.get(this.urlKeyValue)
    if (fromUrl === "open" || fromUrl === "closed") return fromUrl

    const cookie = this.#readCookie()
    if (cookie === "open" || cookie === "closed") return cookie

    return this.defaultStateValue === "open" ? "open" : "closed"
  }

  #visualState() {
    if (!this.hasPaneTarget) return "closed"
    return this.paneTarget.dataset.paneState === "open" ? "open" : "closed"
  }

  // Animates to `state`, persists to cookie, and records it in the URL — the
  // user-driven path. Initial connect and popstate bypass this.
  #commit(state) {
    const screen = this.#actsAsScreen()
    const focusWasInside = this.paneTarget.contains(document.activeElement)
    this.#animate(state)
    this.#applyMetadata(state)
    this.#writeCookie(state)
    if (state === "open") this.#revealStackedPane()
    if (!this.screenValue) {
      this.#pushBrowserUrl(state)
      return
    }
    this.#recordInHistory(state, screen)
    if (state === "open") {
      if (screen) this.paneTarget.focus({ preventScroll: true })
    } else if (screen || focusWasInside) {
      this.#focusToggle()
    }
  }

  // Below lg the overlay covers the page like a screen of its own, so opening
  // it adds a history entry and Back closes it; closing it any other way
  // takes that entry back off. Beside the page on lg+, the URL changes in
  // place and Back leaves the page.
  //
  // The entry the overlay leaves behind is marked closed, so Back lands on a
  // URL that says so. A Back we queued is asynchronous: until it lands, the
  // popstate it fires settles history (see #applyFromHistory).
  #recordInHistory(state, screen) {
    if (this.#leaving) return
    const ownEntry = this.#onOwnEntry()
    if (screen && state === "open" && !ownEntry) {
      window.history.replaceState(window.history.state, "", this.#urlWith("closed"))
      window.history.pushState({ [HISTORY_KEY]: this.urlKeyValue }, "", this.#urlWith("open"))
    } else if (state === "closed" && ownEntry) {
      this.#leaving = true
      window.history.back()
    } else {
      window.history.replaceState(window.history.state, "", this.#urlWith(state))
    }
  }

  // An open pane changes shape when the window crosses lg. Narrowing turns it
  // into the overlay, which needs the entry Back closes it with; widening sets
  // it beside the page, where that entry no longer belongs.
  #followBreakpoint() {
    if (this.#visualState() !== "open") return
    if (this.#actsAsScreen()) {
      this.#recordInHistory("open", true)
    } else if (this.#onOwnEntry()) {
      this.#stepOffOverlayEntry()
    }
  }

  #onOwnEntry() {
    return window.history.state?.[HISTORY_KEY] === this.urlKeyValue
  }

  // Turbo restores a page only from an entry it stamped. Leaving from the
  // overlay's own entry would bring Back to a page Turbo never restores, with
  // the next page still on screen, so stamp it the way Turbo stamps its own.
  // Turbo's stamp replaces the whole state, so the marker goes back on after.
  #stampOwnEntry() {
    if (!this.#onOwnEntry()) return
    window.Turbo?.session?.history?.replace(new URL(window.location.href))
    window.history.replaceState({ ...window.history.state, [HISTORY_KEY]: this.urlKeyValue }, "")
  }

  #actsAsScreen() {
    return this.screenValue && this.dismissOutsideValue && window.innerWidth < MOBILE_BREAKPOINT
  }

  #focusToggle() {
    const toggle = this.toggleTargets.find((candidate) => candidate.offsetParent !== null)
    toggle?.focus({ preventScroll: true })
  }

  // A pane that stacks under the page opens below the fold on a phone, where
  // the tap that opened it would otherwise seem to do nothing.
  #revealStackedPane() {
    if (this.dismissOutsideValue || window.innerWidth >= MOBILE_BREAKPOINT) return
    requestAnimationFrame(() => this.paneTarget.scrollIntoView({ block: "start" }))
  }

  // Back and Forward change the URL without remounting the controller. The
  // overlay's own entry means open; any other entry says what it holds in
  // the URL, and one that says nothing leaves the pane as it is.
  // Turbo's popstate listener runs first and stamps its own state over an
  // entry it finds without one, so the marker survives only in the event and
  // goes back on the entry for the close that will take it back.
  #applyFromHistory(poppedState) {
    if (this.#leaving) {
      this.#leaving = false
      // Reopened while our Back was on its way: record it afresh.
      if (this.#visualState() === "open") this.#recordInHistory("open", this.#actsAsScreen())
      return
    }
    const fromUrl = new URL(window.location.href).searchParams.get(this.urlKeyValue)
    const ownEntry = poppedState?.[HISTORY_KEY] === this.urlKeyValue
    if (ownEntry && this.#actsAsScreen() && !this.#onOwnEntry()) {
      window.history.replaceState({ ...window.history.state, [HISTORY_KEY]: this.urlKeyValue }, "")
    }
    const state = ownEntry ? "open" : fromUrl
    if ((state === "open" || state === "closed") && state !== this.#visualState()) {
      this.#animate(state)
      this.#applyMetadata(state)
      this.#writeCookie(state)
      if (state === "closed" && this.screenValue) this.#focusToggle()
      if (state === "open" && this.#actsAsScreen()) this.paneTarget.focus({ preventScroll: true })
    }
    // Forward can return to the entry a widening stepped off.
    if (ownEntry && !this.#actsAsScreen()) this.#stepOffOverlayEntry()
  }

  // The overlay's entry means nothing beside the page: Back from it would only
  // land on the same page. Step off it and keep the pane open on the entry below.
  #stepOffOverlayEntry() {
    if (this.#leaving) return
    this.#leaving = true
    window.history.back()
  }

  #animate(state) {
    if (state === "open") {
      this.enter()
      this.#scheduleFit()
    } else {
      // Fit once the fade-out ends, which clears the inline height.
      Promise.resolve(this.leave()).finally(() => this.#scheduleFit())
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
    this.fitFrame = null
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
    // No floor: a taller pane would put its end back below the fold, where
    // overscroll-contain stops the wheel from scrolling the page to reach it.
    pane.style.maxHeight = `${Math.max(0, Math.floor(room))}px`
  }

  #applyMetadata(state) {
    if (this.hasPaneTarget) this.paneTarget.dataset.paneState = state
    this.toggleTargets.forEach((toggle) => {
      toggle.setAttribute("aria-expanded", state === "open" ? "true" : "false")
    })
  }

  #urlWith(state) {
    const url = new URL(window.location.href)
    url.searchParams.set(this.urlKeyValue, state)
    return url
  }

  #pushBrowserUrl(state) {
    const url = this.#urlWith(state)
    if (url.toString() !== window.location.href) window.history.pushState({}, "", url)
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

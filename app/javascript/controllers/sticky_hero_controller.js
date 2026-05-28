// Sticky hero summary controller.
//
// The hero lives inside the unified sticky header so the old
// IntersectionObserver-on-a-sentinel approach can't work — the sentinel
// pins along with the header. Instead, listen to window scroll and
// toggle compact mode once the user has scrolled past a small threshold.
//
// <div data-controller="sticky-hero">
//   <div data-sticky-hero-target="hero">
//     <div data-sticky-hero-target="expandedBody">...</div>
//     <div data-sticky-hero-target="compactBody">...</div>
//   </div>
// </div>

import BaseController from "controllers/base_controller"

const COMPACT_SCROLL_THRESHOLD = 80

export default class extends BaseController {
  static targets = ["hero", "expandedBody", "compactBody"]

  connect() {
    super.connect()
    this._isCompact = false

    this._onScroll = () => this.#scheduleUpdate()
    window.addEventListener("scroll", this._onScroll, { passive: true })

    // Apply initial state in case the user lands mid-scroll (e.g. back/forward).
    requestAnimationFrame(() => this.#updateState())
  }

  disconnect() {
    if (this._onScroll) {
      window.removeEventListener("scroll", this._onScroll)
      this._onScroll = null
    }
    if (this._rafId) {
      cancelAnimationFrame(this._rafId)
      this._rafId = null
    }
    super.disconnect()
  }

  scrollToTop(event) {
    event.preventDefault()
    window.scrollTo({ top: 0, behavior: "smooth" })
  }

  #scheduleUpdate() {
    if (this._rafId) return
    this._rafId = requestAnimationFrame(() => {
      this._rafId = null
      this.#updateState()
    })
  }

  #updateState() {
    const shouldCompact = window.scrollY > COMPACT_SCROLL_THRESHOLD
    if (shouldCompact === this._isCompact) return
    this._isCompact = shouldCompact
    this.#applyVisual()
  }

  #applyVisual() {
    const compact = this._isCompact

    if (this.hasExpandedBodyTarget) {
      this.expandedBodyTarget.dataset.compact = compact ? "true" : "false"
    }
    if (this.hasCompactBodyTarget) {
      this.compactBodyTarget.dataset.compact = compact ? "true" : "false"
    }
    if (this.hasHeroTarget) {
      this.heroTarget.classList.toggle("shadow-md", compact)
      this.heroTarget.classList.toggle("rounded-xl", !compact)
      this.heroTarget.classList.toggle("rounded-none", compact)
    }
  }
}

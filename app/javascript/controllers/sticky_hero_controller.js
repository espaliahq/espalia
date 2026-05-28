// Sticky hero summary controller.
//
// Toggles compact/expanded visual state on scroll. Two pieces of
// pitfall-avoidance:
//
// 1. Hysteresis: compact at COMPACT_THRESHOLD, only expand back when
//    the user is essentially at the top of the page. Without this, the
//    height change from a toggle puts the scroll position right back
//    across the threshold and the state flickers.
//
// 2. Scroll compensation: when the hero shrinks (or grows), the
//    document height changes, which shifts every element below.
//    Without compensation the user's visible content jumps. We
//    `scrollBy` the height delta so the user keeps seeing the same
//    content they were looking at before the toggle.
//
// <div data-controller="sticky-hero">
//   <div data-sticky-hero-target="hero">
//     <div data-sticky-hero-target="expandedBody">...</div>
//     <div data-sticky-hero-target="compactBody">...</div>
//   </div>
// </div>

import BaseController from "controllers/base_controller"

const COMPACT_THRESHOLD = 80
const EXPAND_THRESHOLD = 1

export default class extends BaseController {
  static targets = ["hero", "expandedBody", "compactBody"]

  connect() {
    super.connect()
    this._isCompact = false
    // First state apply (after connect) must not compensate scroll —
    // the user hasn't scrolled; they (or a Turbo Stream) just landed
    // on the page in a scrolled state. Compensating would jump them
    // back to the top of the document.
    this._compensateScroll = false

    this._onScroll = () => this.#scheduleUpdate()
    window.addEventListener("scroll", this._onScroll, { passive: true })

    requestAnimationFrame(() => {
      this.#updateState()
      this._compensateScroll = true
    })
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
    const scrollY = window.scrollY
    let nextState
    if (this._isCompact) {
      nextState = scrollY > EXPAND_THRESHOLD
    } else {
      nextState = scrollY > COMPACT_THRESHOLD
    }
    if (nextState === this._isCompact) return

    const heightBefore = this.hasHeroTarget ? this.heroTarget.offsetHeight : 0
    this._isCompact = nextState
    this.#applyVisual()

    if (this.hasHeroTarget && this._compensateScroll) {
      const heightAfter = this.heroTarget.offsetHeight
      const diff = heightBefore - heightAfter
      // Positive when shrinking (compact) → scroll down to keep visible
      // content stable. Negative when expanding → scroll up by the same.
      if (diff !== 0) window.scrollBy(0, diff)
    }
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

// Sticky hero summary controller.
//
// The hero element is always `sticky top-0 z-20` (set server-side).
// This controller only toggles the compact/expanded visual state.
//
// The sentinel sits ABOVE the hero as a sibling. When it scrolls out
// of view, the hero is visually sticking and we switch to compact mode.
// When it scrolls back into view, we switch back to expanded mode.
//
// <div data-controller="sticky-hero">
//   <div data-sticky-hero-target="sentinel"></div>
//   <div data-sticky-hero-target="hero" class="sticky top-0 z-20">
//     <div data-sticky-hero-target="expandedBody">...</div>
//     <div data-sticky-hero-target="compactBody">...</div>
//   </div>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["hero", "sentinel", "expandedBody", "compactBody"]

  connect() {
    super.connect()
    this._isCompact = false

    this._observer = new IntersectionObserver(
      (entries) => {
        const shouldCompact = !entries[0].isIntersecting
        if (shouldCompact === this._isCompact) return
        this._isCompact = shouldCompact
        this.#applyVisual()
      },
      { threshold: 0 }
    )

    if (this.hasSentinelTarget) {
      this._observer.observe(this.sentinelTarget)
    }
  }

  disconnect() {
    if (this._observer) {
      this._observer.disconnect()
      this._observer = null
    }
    super.disconnect()
  }

  scrollToTop(event) {
    event.preventDefault()
    window.scrollTo({ top: 0, behavior: "smooth" })
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

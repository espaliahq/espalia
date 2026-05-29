// Category navigation controller mounted on the sticky header wrapper.
//
// Owns three pieces of behaviour:
//
// 1. Publishes a `--sticky-header-h` CSS custom property on the root
//    so category section headings can sit just below the unified
//    sticky header (`top: var(--sticky-header-h)`).
//
// 2. Smooth-scrolls to a category section when its chip is clicked,
//    accounting for the unified header's height instead of relying on
//    the browser's `scroll-margin-top` (the header is taller than
//    Tailwind's static `scroll-mt-*` utilities can express).
//
// 3. Updates the active chip (`aria-current="page"`) as the user
//    scrolls through category sections, using IntersectionObserver
//    with a top margin equal to the sticky header height.
//
// <div data-controller="category-nav">
//   <nav id="category-tabs">
//     <a href="#category-X" data-category-id="X" data-action="click->category-nav#scrollTo">…</a>
//   </nav>
// </div>

import BaseController from "controllers/base_controller"

const ACTIVE_CHIP_CLASSES = ["bg-gray-900", "dark:bg-white", "text-white", "dark:text-gray-900"]
const INACTIVE_CHIP_CLASSES = [
  "bg-gray-100", "dark:bg-gray-800", "text-gray-700", "dark:text-gray-300",
  "hover:bg-gray-200", "dark:hover:bg-gray-700", "transition-colors"
]

export default class extends BaseController {
  connect() {
    super.connect()
    this.#publishHeaderHeight()

    this._resizeObserver = new ResizeObserver(() => this.#publishHeaderHeight())
    this._resizeObserver.observe(this.element)

    this._onScroll = () => this.#scheduleActiveCategoryUpdate()
    window.addEventListener("scroll", this._onScroll, { passive: true })

    // Defer the first highlight to after layout so the sticky header
    // has its real measured height.
    requestAnimationFrame(() => this.#scheduleActiveCategoryUpdate())
  }

  disconnect() {
    if (this._resizeObserver) {
      this._resizeObserver.disconnect()
      this._resizeObserver = null
    }
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

  scrollTo(event) {
    event.preventDefault()
    const categoryId = event.currentTarget.dataset.categoryId
    if (!categoryId) return
    const section = document.getElementById(`category-${categoryId}`)
    if (!section) return

    // Smooth scroll directly. The earlier pre-scroll-to-200 caused a
    // visible flicker (page jumped to the first category before
    // scrolling to the target). A post-animation settle pass corrects
    // any drift if sticky-hero compacts mid-scroll.
    const target = () => Math.max(
      0,
      section.getBoundingClientRect().top + window.scrollY - this.element.offsetHeight - 8
    )
    window.scrollTo({ top: target(), behavior: "smooth" })
    setTimeout(() => {
      const sectionTop = section.getBoundingClientRect().top
      const desired = this.element.offsetHeight + 8
      if (Math.abs(sectionTop - desired) > 3) {
        window.scrollTo({ top: target(), behavior: "instant" })
      }
    }, 600)

    // Lock the clicked chip as active and suppress scroll-based detection
    // for the animation window. Otherwise the last scroll event of the
    // smooth animation (slightly short of the target) measures the
    // section as still below the threshold and marks the previous
    // section active — leaving the clicked chip mismatched with the
    // visible section.
    this.#setActiveCategory(categoryId)
    this._suppressActiveUpdateUntil = Date.now() + 900

    this.#pushFocusState({ level: "category", categoryId })
  }

  scrollToTop(event) {
    event.preventDefault()
    window.scrollTo({ top: 0, behavior: "smooth" })
    this.#setActiveCategory(null)
    this._suppressActiveUpdateUntil = Date.now() + 900
    this.#pushFocusState({ level: "framework", categoryId: null })
  }

  // Updates the browser URL (?category=…) and broadcasts the focus
  // change so the activity feed narrows to match the clicked badge.
  // Clears capability/level params — switching category invalidates
  // any prior cell focus.
  #pushFocusState({ level, categoryId }) {
    const url = new URL(window.location)
    if (categoryId) {
      url.searchParams.set("category", categoryId)
    } else {
      url.searchParams.delete("category")
    }
    url.searchParams.delete("capability")
    url.searchParams.delete("level_ordinal")
    window.history.pushState({}, "", url)

    window.dispatchEvent(new CustomEvent("matrix:focus-changed", {
      detail: {
        level,
        categoryId,
        capabilityId: null,
        capabilityStableId: null,
        levelOrdinal: null,
        expectationId: null
      }
    }))
  }

  // `offsetHeight` rounds to an integer — when the real header height
  // is fractional (Hi-DPI displays, subpixel scrolling, the hero's
  // scroll-driven collapse), `--sticky-header-h` can land 0.5–1px
  // shorter than the actual header bottom. The category section's
  // sticky div then sits a hair below the header's bottom edge,
  // revealing a thin strip of scrolling content through the gap.
  // `getBoundingClientRect().height` gives sub-pixel precision; we
  // round up to guarantee the section header always sits AT OR BELOW
  // the unified header's bottom edge, never above it.
  #publishHeaderHeight() {
    const h = Math.ceil(this.element.getBoundingClientRect().height)
    document.documentElement.style.setProperty("--sticky-header-h", `${h}px`)
  }

  // On every scroll, find the section whose top has scrolled just past
  // the bottom of the sticky header — that's the category "in view"
  // and gets its chip activated.
  //
  // Suppressed for ~900ms after a programmatic chip click so the
  // explicitly-clicked active state survives the smooth-scroll animation
  // (whose final scroll events fire before the layout fully settles).
  #scheduleActiveCategoryUpdate() {
    if (this._rafId) return
    if (this._suppressActiveUpdateUntil &&
        Date.now() < this._suppressActiveUpdateUntil) return
    this._rafId = requestAnimationFrame(() => {
      this._rafId = null
      this.#updateActiveCategory()
    })
  }

  #updateActiveCategory() {
    const sections = document.querySelectorAll("section[data-category-id]")
    if (sections.length === 0) return

    const threshold = this.element.getBoundingClientRect().bottom + 16
    let active = sections[0]
    sections.forEach(section => {
      if (section.getBoundingClientRect().top <= threshold) active = section
    })

    this.#setActiveCategory(active.dataset.categoryId)
  }

  #setActiveCategory(categoryId) {
    const chips = this.element.querySelectorAll("nav#category-tabs a[data-category-id]")
    chips.forEach(chip => {
      this.#toggleChipActive(chip, chip.dataset.categoryId === categoryId)
    })
    // "All" chip is only active when no category is in focus.
    const allChip = this.element.querySelector("nav#category-tabs a[data-all-chip]")
    if (allChip) this.#toggleChipActive(allChip, categoryId == null)
  }

  #toggleChipActive(chip, isActive) {
    if (isActive) {
      chip.setAttribute("aria-current", "page")
      chip.classList.remove(...INACTIVE_CHIP_CLASSES)
      chip.classList.add(...ACTIVE_CHIP_CLASSES)
    } else {
      chip.removeAttribute("aria-current")
      chip.classList.remove(...ACTIVE_CHIP_CLASSES)
      chip.classList.add(...INACTIVE_CHIP_CLASSES)
    }
  }
}

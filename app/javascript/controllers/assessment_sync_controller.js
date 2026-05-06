// Observes the assessment-sync-signal element for changes from ActionCable
// broadcasts and triggers a reload of the assessment matrix Turbo Frame.
//
// Saves and restores matrix toggle state (expanded rows, collapsed categories)
// across reloads so the user doesn't lose their place.
//
// Usage:
//   <div data-controller="assessment-sync">
//     <turbo-stream-from ...>
//     <div id="assessment-sync-signal" data-assessment-sync-target="signal"></div>
//     <turbo-frame id="assessment-matrix" data-assessment-sync-target="frame" src="...">
//       <table data-controller="matrix">...</table>
//     </turbo-frame>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["signal", "frame", "scoringFrame", "activityFrame"]

  connect() {
    super.connect()
    this.#observeSignal()
    this.#listenForFrameLoad()
  }

  disconnect() {
    this._observer?.disconnect()
    super.disconnect()
  }

  // private

  #observeSignal() {
    if (!this.hasSignalTarget) return

    this._observer = new MutationObserver(() => {
      this.#reloadFrame()
    })

    // Watch the signal's parent for childList changes (Turbo Stream replace swaps the element)
    this._observer.observe(this.signalTarget.parentElement, {
      childList: true,
      subtree: false
    })
  }

  #listenForFrameLoad() {
    if (this.hasFrameTarget) {
      this.frameTarget.addEventListener("turbo:frame-load", () => {
        this.#restoreToggleState()
        this.#syncScoringFrameCategory()
      })
    }

    if (this.hasScoringFrameTarget) {
      this.scoringFrameTarget.addEventListener("turbo:frame-load", () => {
        this.#updateScoreBadge()
      })
    }
  }

  #reloadFrame() {
    this.#saveToggleState()

    // Reload matrix frame
    if (this.hasFrameTarget) {
      const src = this.frameTarget.getAttribute("src")
      if (src) {
        this.frameTarget.src = ""
        this.frameTarget.src = src
      }
    }

    // Reload scoring panel frame, syncing category from the matrix frame
    if (this.hasScoringFrameTarget) {
      const src = this.scoringFrameTarget.getAttribute("src")
      if (src) {
        const scoringUrl = new URL(src, window.location.origin)
        const matrixCategory = this.#activeCategory()
        if (matrixCategory) {
          scoringUrl.searchParams.set("category", matrixCategory)
        }
        const updatedSrc = scoringUrl.toString()
        this.scoringFrameTarget.src = ""
        this.scoringFrameTarget.src = updatedSrc
      }
    }

    // Reload the activity feed frame so newly-landed events surface
    // without a page refresh. Lazy-loaded frames have no src until first
    // load, so guard accordingly.
    if (this.hasActivityFrameTarget) {
      const src = this.activityFrameTarget.getAttribute("src")
      if (src) {
        this.activityFrameTarget.src = ""
        this.activityFrameTarget.src = src
      }
    }
  }

  #updateScoreBadge() {
    const panel = this.scoringFrameTarget.querySelector("#scoring-panel")
    const badge = document.getElementById("score-percentage-badge")
    if (!panel || !badge) return

    const pct = panel.dataset.performancePct
    const ratio = parseInt(pct, 10) / 100.0
    const color = ratio >= 1.0 ? "text-green-600 dark:text-green-400" :
                  ratio >= 0.8 ? "text-amber-600 dark:text-amber-400" :
                  "text-red-600 dark:text-red-400"

    badge.textContent = `${pct}%`
    badge.className = `ml-1 font-semibold ${color}`
  }

  #saveToggleState() {
    const table = this.frameTarget.querySelector("table")
    if (!table) return

    // Save expanded row
    const expandedRow = table.querySelector("[data-matrix-target='expandedRow']:not(.hidden)")
    this._expandedCapabilityId = expandedRow?.dataset.capabilityId || null

    // Save collapsed categories
    this._collapsedCategories = new Set()
    table.querySelectorAll("[data-matrix-target='categoryHeader']").forEach(header => {
      const categoryId = header.dataset.categoryId
      if (!categoryId) return

      // Check if next sibling row is hidden (category is collapsed)
      let sibling = header.nextElementSibling
      if (sibling && !sibling.dataset?.matrixTarget?.includes("categoryHeader") &&
          sibling.classList.contains("hidden")) {
        this._collapsedCategories.add(categoryId)
      }
    })
  }

  #restoreToggleState() {
    const table = this.frameTarget.querySelector("table")
    if (!table) return

    // Restore expanded row
    if (this._expandedCapabilityId) {
      const expandedRow = table.querySelector(
        `[data-matrix-target='expandedRow'][data-capability-id='${this._expandedCapabilityId}']`
      )
      if (expandedRow) {
        expandedRow.classList.remove("hidden")
        const compactRow = table.querySelector(
          `[data-matrix-target='row'][data-capability-id='${this._expandedCapabilityId}']`
        )
        const chevron = compactRow?.querySelector("[data-matrix-target='rowChevron']")
        if (chevron) chevron.classList.add("rotate-90")
      }
      this._expandedCapabilityId = null
    }

    // Restore collapsed categories
    if (this._collapsedCategories?.size > 0) {
      table.querySelectorAll("[data-matrix-target='categoryHeader']").forEach(header => {
        const categoryId = header.dataset.categoryId
        if (!categoryId || !this._collapsedCategories.has(categoryId)) return

        // Hide all rows until next category header
        let sibling = header.nextElementSibling
        while (sibling) {
          if (sibling.dataset?.matrixTarget?.includes("categoryHeader")) break
          sibling.classList.add("hidden")
          sibling = sibling.nextElementSibling
        }

        const chevron = header.querySelector("[data-matrix-target='categoryChevron']")
        if (chevron) {
          chevron.classList.remove("rotate-90")
          chevron.classList.add("rotate-0")
        }
      })
      this._collapsedCategories = null
    }
  }

  // Reloads the scoring frame with the active category from the matrix frame.
  // Called after every matrix frame load (tab switch, rating, etc.)
  #syncScoringFrameCategory() {
    if (!this.hasScoringFrameTarget) return

    const matrixCategory = this.#activeCategory()
    const currentSrc = this.scoringFrameTarget.getAttribute("src")
    if (!currentSrc) return

    try {
      const scoringUrl = new URL(currentSrc, window.location.origin)
      const currentCategory = scoringUrl.searchParams.get("category")

      // Only reload if the category actually changed
      if (matrixCategory && matrixCategory !== currentCategory) {
        scoringUrl.searchParams.set("category", matrixCategory)
        this.scoringFrameTarget.src = scoringUrl.toString()
      }
    } catch {
      // ignore invalid URLs
    }
  }

  // Extracts the active category from the matrix frame's src URL.
  #activeCategory() {
    if (!this.hasFrameTarget) return null

    const src = this.frameTarget.getAttribute("src")
    if (!src) return null

    try {
      const url = new URL(src, window.location.origin)
      return url.searchParams.get("category")
    } catch {
      return null
    }
  }
}

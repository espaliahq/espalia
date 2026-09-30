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

const LENS_PARAMS = ["as_role", "as_level"]

export default class extends BaseController {
  static targets = ["signal", "frame", "scoringFrame", "activityFrame"]

  connect() {
    super.connect()
    this.#observeSignal()
    this.#listenForFrameLoad()
    this.#listenForOwnSubmits()
  }

  disconnect() {
    this._observer?.disconnect()
    if (this._pointerListener) {
      this.element.removeEventListener("pointerdown", this._pointerListener, true)
      this.element.removeEventListener("mousedown", this._pointerListener, true)
      this._pointerListener = null
    }
    if (this._clickListener) {
      this.element.removeEventListener("click", this._clickListener, true)
      this._clickListener = null
    }
    if (this._submitListener) {
      document.removeEventListener("turbo:submit-start", this._submitListener)
      this._submitListener = null
    }
    super.disconnect()
  }

  // private

  #observeSignal() {
    if (!this.hasSignalTarget) return

    this._observer = new MutationObserver(() => {
      // Skip the matrix + scoring frame reloads when the broadcast was
      // triggered by THIS client's own form submit (e.g. a rating). The
      // direct Turbo Stream response already updated those cells —
      // re-fetching the whole matrix frame would flicker and reset
      // scroll position. The suppress window is set in
      // #listenForOwnSubmits and expires shortly after the submit.
      //
      // The activity frame is NOT part of the rating turbo-stream
      // response, so we always reload it so the rater sees their own
      // new entry appear in the sidebar.
      const suppress = this._suppressReloadUntil &&
        performance.now() < this._suppressReloadUntil
      this.#reloadFrame({ skipMatrixAndScoring: suppress })
    })

    // Watch the signal's parent for childList changes (Turbo Stream replace swaps the element)
    this._observer.observe(this.signalTarget.parentElement, {
      childList: true,
      subtree: false
    })
  }

  // Suppress the next signal-triggered frame reload for a short window
  // after any user action originating from inside this controller's
  // element. Ratings, alignment toggles, and evidence submissions all
  // return targeted Turbo Stream responses that already update the
  // matrix locally — the ActionCable broadcast that follows is meant
  // for OTHER viewers, and re-fetching the whole frame for the user
  // who just acted causes flicker + scroll loss.
  //
  // Two arming signals:
  //   1. `click` (capture phase) on a button/anchor inside this
  //      controller — set the flag the moment the user acts, before
  //      the network round-trip starts. On slow CI runners the
  //      broadcast can arrive faster than `turbo:submit-start` fires.
  //   2. `turbo:submit-start` — covers form submissions that don't go
  //      through a button click (programmatic submits).
  #listenForOwnSubmits() {
    const arm = () => {
      // 5s covers a broadcast round-trip with generous CI headroom
      // without holding off legitimate reloads from other users for
      // long enough to be noticed.
      this._suppressReloadUntil = performance.now() + 5000
    }

    // Arm on the EARLIEST possible signal of a user-initiated form
    // SUBMIT — pointerdown/mousedown/click on a real submit control
    // inside this controller's element, AND only when that control
    // belongs to a form contained by this matrix layout. This
    // narrowing prevents arming on plain links / nav buttons /
    // dropdown toggles, which would otherwise hide unrelated
    // ActionCable updates from other users.
    const submitControlFor = (event) =>
      event.target?.closest?.(
        "button[type='submit'], button:not([type]), input[type='submit']"
      )

    const armForOwnSubmit = (event) => {
      const control = submitControlFor(event)
      if (control?.form && this.element.contains(control.form)) arm()
    }

    this._pointerListener = armForOwnSubmit
    this.element.addEventListener("pointerdown", this._pointerListener, true)
    this.element.addEventListener("mousedown", this._pointerListener, true)

    this._clickListener = armForOwnSubmit
    this.element.addEventListener("click", this._clickListener, true)

    this._submitListener = (event) => {
      if (!event.target || !this.element.contains(event.target)) return
      arm()
    }
    document.addEventListener("turbo:submit-start", this._submitListener)
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

    if (this.hasActivityFrameTarget) {
      this.activityFrameTarget.addEventListener("turbo:frame-load", () => {
        this.#restoreActivityScroll()
      })
    }
  }

  #reloadFrame({ skipMatrixAndScoring = false } = {}) {
    if (!skipMatrixAndScoring) {
      this.#saveToggleState()
    }
    this.#saveActivityScroll()

    // Reload matrix frame. Merge in `capability` and `level_ordinal`
    // params from the BROWSER URL (kept current by matrix_controller's
    // URL sync) so focus state survives the reload — without this,
    // the frame's stale `src` (initial server render) drops focus
    // every time a rating triggers a CurrentAssessment broadcast.
    if (!skipMatrixAndScoring && this.hasFrameTarget) {
      const src = this.frameTarget.getAttribute("src")
      if (src) {
        const merged = this.#mergeFocusParams(src)
        this.frameTarget.src = ""
        this.frameTarget.src = merged
      }
    }

    // Reload scoring panel frame, syncing category from the matrix frame
    if (!skipMatrixAndScoring && this.hasScoringFrameTarget) {
      const src = this.scoringFrameTarget.getAttribute("src")
      if (src) {
        const scoringUrl = new URL(this.#mergeLensParams(src), window.location.origin)
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

  #saveActivityScroll() {
    const pane = document.getElementById("assessment-activity-pane")
    this._activityScrollTop = pane ? pane.scrollTop : null
  }

  #restoreActivityScroll() {
    const pane = document.getElementById("assessment-activity-pane")
    if (pane && this._activityScrollTop != null) {
      pane.scrollTop = this._activityScrollTop
    }
    this._activityScrollTop = null
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

  // Copies the lens (as_role / as_level) from the browser URL onto a frame
  // src, so a broadcast reload reads the role and level the page is read
  // against instead of snapping back to the home role.
  #mergeLensParams(src) {
    let target
    try {
      target = new URL(src, window.location.origin)
    } catch {
      return src
    }
    const browser = new URL(window.location)
    for (const name of LENS_PARAMS) {
      const value = browser.searchParams.get(name)
      if (value) {
        target.searchParams.set(name, value)
      } else {
        target.searchParams.delete(name)
      }
    }
    return target.toString()
  }

  // Merges focus-related params (capability, level_ordinal) from the
  // browser URL into the given matrix frame src. The matrix controller
  // pushes these params via history.pushState on focus changes, but
  // does not (and cannot, without triggering a fetch) mutate the
  // frame's src attribute — so on reload we re-merge them here.
  #mergeFocusParams(src) {
    let target
    try {
      target = new URL(this.#mergeLensParams(src), window.location.origin)
    } catch {
      return src
    }
    const browser = new URL(window.location)
    for (const name of ["capability", "level_ordinal"]) {
      const value = browser.searchParams.get(name)
      if (value) {
        target.searchParams.set(name, value)
      } else {
        target.searchParams.delete(name)
      }
    }
    // Carry the per-capability selected-level map (levels[<stable>]=<ord>)
    // so a broadcast-driven reload keeps every card on the level the viewer
    // selected — not just the single focused cell. Replace the target's map
    // wholesale with the browser URL's (the source of truth kept current by
    // matrix_controller on every chip click).
    for (const key of [...target.searchParams.keys()]) {
      if (key.startsWith("levels[")) target.searchParams.delete(key)
    }
    for (const [key, value] of browser.searchParams.entries()) {
      if (key.startsWith("levels[")) target.searchParams.append(key, value)
    }
    return target.toString()
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

// Activity feed controller.
//
// Owns three pieces of client-side state for the assessment activity sidebar:
// - filter chip (all | ratings | evidence | alignment)
// - focus mode (highlight | filter), persisted in a cookie
// - matrix focus state, picked up via matrix:focus-changed
//
// Reapplies entry visibility + amber-accent styling whenever any of the
// three changes. Click on a focusable entry dispatches activity:navigate
// so the matrix expands the matching row and scrolls to it.

import BaseController from "controllers/base_controller"

const COOKIE_NAME = "assessment_activity_focus_mode"
const COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365
const VALID_FILTERS = ["all", "ratings", "evidence", "alignment"]
const VALID_MODES = ["highlight", "filter"]

export default class extends BaseController {
  static targets = ["entry", "filterChip", "modeSegment", "focusBanner", "focusBannerLabel"]

  connect() {
    super.connect()
    this.filter = "all"
    this.mode = this.#readCookieMode()
    this.focus = { level: "framework", capabilityStableId: null, levelOrdinal: null }
    this.#paintModeSegments()
    this.#applyState()
  }

  setFilter(event) {
    const next = event.params.filter
    if (!VALID_FILTERS.includes(next)) return
    this.filter = next
    this.#paintFilterChips()
    this.#applyState()
  }

  setMode(event) {
    const next = event.params.mode
    if (!VALID_MODES.includes(next)) return
    this.mode = next
    this.#writeCookieMode(next)
    this.#paintModeSegments()
    this.#applyState()
  }

  // Listens for matrix:focus-changed — extracts capability_stable_id +
  // level_ordinal from the event detail. Tolerates payloads that don't
  // include the stable id (framework-level focus, framework explorer).
  onMatrixFocusChanged(event) {
    const { level, capabilityStableId, levelOrdinal } = event.detail || {}
    this.focus = {
      level: level || "framework",
      capabilityStableId: capabilityStableId || null,
      levelOrdinal: (typeof levelOrdinal === "number") ? levelOrdinal : null
    }
    this.#applyState()
  }

  // Click on a focusable entry — navigates the matrix to the entry's
  // (capability, level) coord. Reuses the matrix's #navigateToEntity
  // handler via the activity:navigate event the matrix wrapper listens
  // for.
  focusEntry(event) {
    const el = event.currentTarget
    const capabilityStableId = el.dataset.capabilityStableId
    const levelOrdinal = parseInt(el.dataset.levelOrdinal, 10)
    if (!capabilityStableId || isNaN(levelOrdinal)) return

    window.dispatchEvent(new CustomEvent("activity:navigate", {
      detail: {
        level: "cell",
        categoryId: null,
        capabilityId: null,
        capabilityStableId,
        levelOrdinal
      }
    }))
  }

  // private

  #applyState() {
    this.entryTargets.forEach(entry => {
      const matches = this.#matchesFocus(entry)
      const inFilter = this.#inFilter(entry)
      const filterModeHidden = this.mode === "filter" && this.#hasActiveFocus() && !matches
      const filteredOut = !inFilter

      entry.dataset.match = (this.#hasActiveFocus() && matches) ? "true" : "false"
      entry.dataset.hidden = (filteredOut || filterModeHidden) ? "true" : "false"
    })

    if (this.hasFocusBannerTarget) {
      const show = this.mode === "filter" && this.#hasActiveFocus()
      this.focusBannerTarget.classList.toggle("hidden", !show)
      if (show && this.hasFocusBannerLabelTarget) {
        this.focusBannerLabelTarget.textContent = this.#focusBannerLabel()
      }
    }
  }

  #matchesFocus(entry) {
    if (!this.#hasActiveFocus()) return false

    const entryCapId = entry.dataset.capabilityStableId
    const entryLevel = parseInt(entry.dataset.levelOrdinal, 10)
    if (!entryCapId) return false

    if (this.focus.level === "capability") {
      return entryCapId === this.focus.capabilityStableId
    }
    if (this.focus.level === "cell") {
      return entryCapId === this.focus.capabilityStableId &&
             entryLevel === this.focus.levelOrdinal
    }
    return false
  }

  #hasActiveFocus() {
    return ["capability", "cell"].includes(this.focus.level) &&
           this.focus.capabilityStableId
  }

  #inFilter(entry) {
    if (this.filter === "all") return true
    return entry.dataset.kindGroup === this.filter
  }

  #focusBannerLabel() {
    if (this.focus.level === "cell") return `at L${this.focus.levelOrdinal}`
    return "for the focused capability"
  }

  #paintFilterChips() {
    this.filterChipTargets.forEach(chip => {
      const pressed = chip.dataset.activityFeedFilterParam === this.filter
      chip.setAttribute("aria-pressed", pressed ? "true" : "false")
    })
  }

  #paintModeSegments() {
    this.modeSegmentTargets.forEach(seg => {
      const pressed = seg.dataset.activityFeedModeParam === this.mode
      seg.setAttribute("aria-pressed", pressed ? "true" : "false")
    })
  }

  #readCookieMode() {
    const match = document.cookie.match(new RegExp("(?:^|; )" + COOKIE_NAME + "=([^;]+)"))
    const value = match ? decodeURIComponent(match[1]) : null
    return VALID_MODES.includes(value) ? value : "highlight"
  }

  #writeCookieMode(value) {
    document.cookie =
      `${COOKIE_NAME}=${encodeURIComponent(value)}; ` +
      `path=/; max-age=${COOKIE_MAX_AGE_SECONDS}; SameSite=Lax`
  }
}

// Activity feed controller.
//
// Owns three pieces of client-side state for the assessment activity sidebar:
// - filter chip (all | ratings | evidence | alignment)
// - focus mode (highlight | filter), persisted in a cookie
// - matrix focus state, picked up via matrix:focus-changed
//
// Reapplies entry visibility + amber-accent styling whenever any of the
// three changes. The amber accent only applies in Highlight mode, where
// matches and non-matches coexist; in Filter mode the non-matches are
// hidden, so the visible entries are the focus and need no accent. Click
// on a focusable entry dispatches activity:navigate so the matrix expands
// the matching row and scrolls to it.

import BaseController from "controllers/base_controller"

const COOKIE_NAME = "assessment_activity_focus_mode"
const COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365
const VALID_FILTERS = ["all", "ratings", "evidence", "comments", "alignment"]
const VALID_MODES = ["highlight", "filter"]

export default class extends BaseController {
  static targets = ["entry", "filterChip", "modeSegment", "focusBanner", "focusBannerLabel"]

  connect() {
    super.connect()
    this.filter = "all"
    this.mode = this.#readCookieMode()
    this.focus = this.#readMatrixFocusFromDom()
    this.#paintFilterChips()
    this.#paintModeSegments()
    this.#applyState()
    this.#scrollFirstMatchIntoView()
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
    this.#scrollFirstMatchIntoView()
  }

  // Listens for matrix:focus-changed — extracts categoryId,
  // capability_stable_id, and level_ordinal from the event detail.
  // Tolerates payloads that don't include any/all (framework-level
  // focus, framework explorer).
  onMatrixFocusChanged(event) {
    const { level, categoryId, capabilityStableId, levelOrdinal } = event.detail || {}
    this.focus = {
      level: level || "framework",
      categoryId: categoryId || null,
      capabilityStableId: capabilityStableId || null,
      levelOrdinal: (typeof levelOrdinal === "number") ? levelOrdinal : null
    }
    this.#applyState()
    this.#scrollFirstMatchIntoView()
  }

  // Resets the feed's internal focus to "show all" without changing
  // the matrix. Useful when the user wants a quick peek at every entry
  // without collapsing the row they're working in. Subsequent matrix
  // focus changes (row expand, tab switch, broadcast reload) will
  // re-apply focus.
  clearFocus() {
    this.focus = { level: "framework", categoryId: null, capabilityStableId: null, levelOrdinal: null }
    this.#applyState()
  }

  // Click on a focusable entry — navigates the matrix to the entry's
  // (capability, level) coord. Reuses the matrix's #navigateToEntity
  // handler via the activity:navigate event the matrix wrapper listens
  // for. Includes categoryId so the matrix can switch to the right
  // tab if the entry's capability lives outside the active one.
  focusEntry(event) {
    const el = event.currentTarget
    const capabilityStableId = el.dataset.capabilityStableId
    const levelOrdinal = parseInt(el.dataset.levelOrdinal, 10)
    if (!capabilityStableId || isNaN(levelOrdinal)) return

    window.dispatchEvent(new CustomEvent("activity:navigate", {
      detail: {
        level: "cell",
        categoryId: el.dataset.categoryId || null,
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

      // The amber-accent highlight only earns its keep in Highlight mode,
      // where matching and non-matching entries sit side by side. In Filter
      // mode the non-matches are hidden, so every visible entry already
      // belongs to the focus — accenting them all is redundant noise.
      const highlight = this.mode === "highlight" && this.#hasActiveFocus() && matches
      entry.dataset.match = highlight ? "true" : "false"
      entry.dataset.hidden = (filteredOut || filterModeHidden) ? "true" : "false"
    })

    // The focus banner surfaces in BOTH modes whenever there's an active
    // focus — it doubles as the "← Show all activity" breadcrumb. In
    // Filter mode the wording reads more strongly ("Showing N entries
    // for X"); in Highlight mode it's a quieter label since the rest
    // of the feed is still visible.
    if (this.hasFocusBannerTarget) {
      const show = this.#hasActiveFocus()
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
    const entryCategoryId = entry.dataset.categoryId

    if (this.focus.level === "category") {
      return entryCategoryId && entryCategoryId === this.focus.categoryId
    }
    if (this.focus.level === "capability") {
      return entryCapId && entryCapId === this.focus.capabilityStableId
    }
    if (this.focus.level === "cell") {
      return entryCapId === this.focus.capabilityStableId &&
             entryLevel === this.focus.levelOrdinal
    }
    return false
  }

  #hasActiveFocus() {
    if (this.focus.level === "category") return !!this.focus.categoryId
    if (["capability", "cell"].includes(this.focus.level)) {
      return !!this.focus.capabilityStableId
    }
    return false
  }

  #inFilter(entry) {
    if (this.filter === "all") return true
    return entry.dataset.kindGroup === this.filter
  }

  // Pulls the matrix's current focus state from the DOM. Solves the
  // ordering problem where matrix#connect dispatches matrix:focus-changed
  // before activity-feed has bound its listener — without this, the
  // feed would miss the initial category focus on every page load and
  // every Turbo Frame swap.
  //
  // Card-layout signal: a capability card stamped `data-focused="true"`
  // by matrix_controller#setFocus represents capability-or-cell focus
  // (matrix_controller stamps the same attribute for both). The feed
  // reconnects when its turbo-frame loads lazily — without this signal
  // it would silently downgrade to category-level focus on every frame
  // load, undoing whatever the user just clicked.
  //
  // Cell-vs-capability disambiguation: the browser URL is the source
  // of truth for cell focus (the chip click pushes `?level_ordinal=`
  // via `#syncFocusToUrl`). Without reading `level_ordinal` here, every
  // lazy reconnect downgrades cell focus to capability focus and the
  // sidebar widens to all entries across the capability's levels.
  //
  // Table-layout signal: the legacy expandedRow target is still honoured
  // for the framework explorer.
  #readMatrixFocusFromDom() {
    const blank = { level: "framework", categoryId: null, capabilityStableId: null, levelOrdinal: null }
    const matrix = document.querySelector("[data-controller~='matrix']")
    if (!matrix) return blank

    const activeCategoryId = matrix.dataset.matrixActiveCategoryIdValue
    if (!activeCategoryId) return blank

    // Card layout — focused card carries `data-focused="true"`. When
    // multiple cards are focused (shouldn't happen, but be defensive),
    // pick the first.
    const focusedCard = matrix.querySelector(
      "[data-matrix-target='card'][data-focused='true']"
    )
    if (focusedCard) {
      const section = focusedCard.closest("section[data-category-id]")
      const url = new URL(window.location)
      const stableId = focusedCard.dataset.capabilityStableId || null
      const urlStableId = url.searchParams.get("capability")
      const urlOrdRaw = url.searchParams.get("level_ordinal")
      const urlOrd = urlOrdRaw == null ? null : parseInt(urlOrdRaw, 10)
      // Cell focus is signalled by `?capability=` + `?level_ordinal=`
      // matching the focused card's stable_id. Otherwise treat as
      // capability-level.
      const isCell = stableId && urlStableId === stableId &&
                     urlOrd != null && !isNaN(urlOrd)
      return {
        level: isCell ? "cell" : "capability",
        categoryId: section?.dataset.categoryId || activeCategoryId,
        capabilityStableId: stableId,
        levelOrdinal: isCell ? urlOrd : null
      }
    }

    const expandedRow = matrix.querySelector(
      "[data-matrix-target='expandedRow']:not(.hidden)"
    )
    if (expandedRow) {
      return {
        level: "capability",
        categoryId: activeCategoryId,
        capabilityStableId: expandedRow.dataset.capabilityStableId || null,
        levelOrdinal: null
      }
    }
    return {
      level: "category",
      categoryId: activeCategoryId,
      capabilityStableId: null,
      levelOrdinal: null
    }
  }

  #focusBannerLabel() {
    if (this.focus.level === "cell") return `for the focused cell (L${this.focus.levelOrdinal})`
    if (this.focus.level === "capability") return "for the focused capability"
    if (this.focus.level === "category") return "for the active category"
    return "for the focused context"
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

  // In highlight mode, the rest of the feed stays visible, so a matching
  // entry further down the list would otherwise sit off-screen until the
  // user scrolls. Park the first match at the top of the sidebar's
  // visible band every time focus changes — clicking a new focus is
  // "show me what changed", so the match should be the focal point
  // regardless of where the sidebar happened to be scrolled.
  //
  // Scopes the scroll to the sidebar aside directly (rather than calling
  // `scrollIntoView` on the entry, which cascades up and can shift the
  // main page too).
  #scrollFirstMatchIntoView() {
    if (this.mode !== "highlight") return
    if (!this.#hasActiveFocus()) return
    const first = this.entryTargets.find(e => e.dataset.match === "true")
    if (!first) return

    const aside = first.closest("#assessment-activity-pane")
    if (!aside) return

    const entryRect = first.getBoundingClientRect()
    const asideRect = aside.getBoundingClientRect()
    // Land the entry at the top of the aside's visible area, with a
    // small gap so it doesn't sit flush against the sidebar's own
    // sticky header.
    const target = aside.scrollTop + (entryRect.top - asideRect.top) - 8
    aside.scrollTo({ top: Math.max(0, target), behavior: "smooth" })
  }

  #readCookieMode() {
    const match = document.cookie.match(new RegExp("(?:^|; )" + COOKIE_NAME + "=([^;]+)"))
    const value = match ? decodeURIComponent(match[1]) : null
    return VALID_MODES.includes(value) ? value : "filter"
  }

  #writeCookieMode(value) {
    document.cookie =
      `${COOKIE_NAME}=${encodeURIComponent(value)}; ` +
      `path=/; max-age=${COOKIE_MAX_AGE_SECONDS}; SameSite=Lax`
  }
}

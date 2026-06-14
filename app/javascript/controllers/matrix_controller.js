// Matrix controller for Turbo Frame updates and row/category expansion.
//
// Listens for tree:changed events to update the matrix Turbo Frame.
// Manages category collapse and row expansion within the matrix.
//
// When urlSync is enabled (assessment views), synchronises the browser URL
// with category/capability selection so state is shareable via links.
//
// <div data-controller="matrix"
//      data-matrix-base-path-value="/frameworks/abc/matrix"
//      data-action="tree:changed@window->matrix#updateSelection">
//   <turbo-frame id="framework-matrix" data-matrix-target="frame">
//     ...
//   </turbo-frame>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["frame", "row", "expandedRow",
                     "categoryHeader", "rowChevron", "categoryChevron",
                     "scrollContainer", "col", "card"]
  static values = {
    basePath: String,
    urlSync: { type: Boolean, default: false },
    activeCategoryId: { type: String, default: "" }
  }

  connect() {
    super.connect()
    if (this.urlSyncValue) {
      this.#listenForFrameLoad()
    }
    // Current focus context in the explorer matrix. Mirrored in the
    // matrix:focus-changed event payload.
    this.currentFocus = { level: "framework", categoryId: null, capabilityId: null,
                          levelOrdinal: null, expectationId: null }

    // Rating Turbo Stream responses replace the compact cell `<td>`
    // and other sub-elements, which discards the close-button
    // visibility / data-focus-compact state we stamped on focus. The
    // col widths survive (col is in colgroup, not replaced), but
    // visually the cell stops looking focused. Re-apply column focus
    // after every Turbo Stream render so the focus state is whole.
    // Rating Turbo Stream responses replace the compact cell `<td>`
    // and other sub-elements, which discards the close-button
    // visibility and the inline column widths we stamped on focus.
    // (The col widths SHOULD survive — colgroup is separate from
    // tbody — but in practice browsers reset col styles when the
    // table's tbody is mutated mid-layout, and the close button is
    // unconditionally re-rendered as `hidden` from the server.)
    //
    // Watch the matrix element for any child mutation (Turbo Stream
    // replacements show up as childList changes inside our subtree)
    // and re-apply focus when we still consider a cell focused.
    this._mutationObserver = new MutationObserver(() => {
      if (this.currentFocus?.level === "cell" &&
          this.currentFocus.levelOrdinal != null &&
          this.currentFocus.capabilityId != null) {
        this.#applyColumnFocus(this.currentFocus.levelOrdinal,
                                this.currentFocus.capabilityId)
      }
    })
    this._mutationObserver.observe(this.element, { childList: true, subtree: true })

    // Scroll-driven capability focus (assessment card layout only).
    // IntersectionObserver tracks which cards are currently in the
    // visible band below the sticky chrome; the deepest one becomes
    // the focused capability. Cheaper than a scroll listener and
    // automatically updates when cards are added / removed by Turbo
    // Stream replacements. No-op on the framework explorer where
    // `cardTargets` is empty.
    //
    // The observer's initial callback fires on connect with the
    // current intersection state — not on a user scroll. Acting on
    // that would surprise the user (page load shouldn't auto-narrow
    // the activity feed to whatever card happens to sit in the visible
    // band) and override URL / data-attribute-driven initial focus.
    // Gate scroll-driven updates on a real user scroll event so the
    // first reaction is to the user's first scroll, never to the
    // observer's connect-time bootstrap.
    this._intersectingCards = new Set()
    this._capabilityFocusSuppressUntil = 0
    // Renew-on-scroll suppression covers the variable-duration smooth
    // scrolls that explicit clicks trigger (category chip, capability
    // card-header, level chip). A time-based window was too brittle on
    // slow CI — the smooth scroll routinely outlasted 1800ms there.
    // When active, every scroll event renews `_scrollSettleTimer` so
    // the suppression naturally tracks the animation, releasing 250ms
    // after the last scroll event.
    this._suppressionScrollRenew = false
    this._scrollSettleTimer = null
    this._sawUserScroll = false
    // Sticky-category flag: set when an external dispatcher (chip click
    // via category-nav) puts us in category focus. The scroll picker
    // honours it the same way it honours cell focus on its own card —
    // a deliberate, user-chosen state shouldn't get silently downgraded
    // by a delayed scroll tick after the smooth scroll lands. Cleared
    // by any explicit focus action that takes us off category (card
    // header click, level chip click, suggestion-pane nav) and by the
    // next genuine user scroll after the chip-click animation ends.
    this._categoryFocusFromExternal = false
    this._onUserScroll = () => {
      this._sawUserScroll = true
      if (this._suppressionScrollRenew) this.#renewSuppressionUntilScrollStops()
    }
    window.addEventListener("scroll", this._onUserScroll, { passive: true })
    // Listen for `matrix:focus-changed` from external dispatchers
    // (currently `category_nav_controller` when a chip is clicked). The
    // chip click triggers a programmatic scroll that would otherwise
    // fire intersection events and downgrade focus to whichever
    // capability happens to land in the band first — overwriting the
    // explicit category focus mid-animation. Adopt the external state
    // and suppress scroll-driven updates for the animation window.
    this._onExternalFocusChange = (e) => this.#onExternalFocusChange(e)
    window.addEventListener("matrix:focus-changed", this._onExternalFocusChange)
    this.#setupCapabilityScrollObserver()

    this.#dispatchInitialFocus()
  }

  disconnect() {
    if (this._frame && this._frameLoadHandler) {
      this._frame.removeEventListener("turbo:frame-load", this._frameLoadHandler)
      this._frame = null
      this._frameLoadHandler = null
    }
    if (this._mutationObserver) {
      this._mutationObserver.disconnect()
      this._mutationObserver = null
    }
    if (this._capabilityIntersectionObserver) {
      this._capabilityIntersectionObserver.disconnect()
      this._capabilityIntersectionObserver = null
    }
    if (this._cardListMutationObserver) {
      this._cardListMutationObserver.disconnect()
      this._cardListMutationObserver = null
    }
    if (this._capScrollRafId) {
      cancelAnimationFrame(this._capScrollRafId)
      this._capScrollRafId = null
    }
    if (this._capScrollSettleTimer) {
      clearTimeout(this._capScrollSettleTimer)
      this._capScrollSettleTimer = null
    }
    if (this._scrollSettleTimer) {
      clearTimeout(this._scrollSettleTimer)
      this._scrollSettleTimer = null
    }
    if (this._onUserScroll) {
      window.removeEventListener("scroll", this._onUserScroll)
      this._onUserScroll = null
    }
    if (this._onCapabilityScroll) {
      window.removeEventListener("scroll", this._onCapabilityScroll)
      this._onCapabilityScroll = null
    }
    if (this._onExternalFocusChange) {
      window.removeEventListener("matrix:focus-changed", this._onExternalFocusChange)
      this._onExternalFocusChange = null
    }
    super.disconnect()
  }

  // ── Selection Update (Turbo Frame) ── (framework explorer)

  updateSelection(event) {
    const { roleIds, track } = event.detail
    this.#rebuildMatrixFrame({ roleIds, track })
  }

  // Free-text filter changed (framework-search:changed). The text query is
  // an orthogonal axis to role/track: merge it with the role scope currently
  // in the browser URL so neither filter clobbers the other.
  updateSearch(event) {
    const { query } = event.detail || {}
    this.#rebuildMatrixFrame({ query: query ?? "" })
  }

  // Rebuilds the matrix Turbo Frame src from the three filter axes. Any axis
  // not supplied by the caller is read back from the browser URL, so a change
  // to one axis (role selection OR text query) preserves the others.
  #rebuildMatrixFrame({ roleIds, track, query } = {}) {
    if (!this.hasFrameTarget || !this.basePathValue) return

    const current = new URL(window.location)
    const resolvedRoleIds = roleIds ?? current.searchParams.getAll("roles[]")
    const resolvedTrack = track ?? (current.searchParams.get("track") || "both")
    const resolvedQuery = query ?? (current.searchParams.get("q") || "")

    const url = new URL(this.basePathValue, window.location.origin)
    resolvedRoleIds.forEach(id => url.searchParams.append("roles[]", id))
    url.searchParams.set("track", resolvedTrack)
    if (resolvedQuery) url.searchParams.set("q", resolvedQuery)

    this.frameTarget.src = url.toString()

    // Update browser URL for shareability
    this.#updateBrowserUrl(resolvedRoleIds, resolvedTrack, resolvedQuery)
  }

  // ── Category Collapse ──

  toggleCategory(event) {
    event.stopPropagation()
    const trigger = event.currentTarget
    const header = trigger.closest("[data-matrix-target='categoryHeader']") || trigger
    const categoryId = trigger.dataset.categoryId
    if (!categoryId) return

    // Find all rows belonging to this category (sibling rows until next category header)
    const rows = this.#categoryRows(header)
    const isCollapsing = !rows[0]?.classList.contains("hidden")

    rows.forEach(row => row.classList.toggle("hidden", isCollapsing))

    // Rotate chevron
    const chevron = header.querySelector("[data-matrix-target='categoryChevron']")
    if (chevron) {
      chevron.classList.toggle("rotate-90", !isCollapsing)
      chevron.classList.toggle("rotate-0", isCollapsing)
    }
  }

  // ── Row Expansion ──

  toggleRow(event) {
    // Ignore clicks on interactive children (the inline-edit pencil, the
    // row-actions kebab, inline forms, links) so editing or opening the
    // actions menu doesn't also toggle the row. The expand/collapse chevron
    // is an <svg> (not an interactive element), so it still falls through.
    if (event.target.closest("button, a, input, textarea, select, form, [data-controller~='dropdown']")) {
      return
    }

    const row = event.currentTarget
    const capId = row.dataset.capabilityId
    if (!capId) return

    const expandedRow = this.expandedRowTargets.find(
      r => r.dataset.capabilityId === capId
    )
    if (!expandedRow) return

    const isCurrentlyExpanded = !expandedRow.classList.contains("hidden")
    const clickedChevron = event.target.closest("[data-matrix-target='rowChevron']")

    // Only collapse if the chevron was clicked directly; row clicks always expand
    if (isCurrentlyExpanded && !clickedChevron) return

    // Collapse any other expanded row (accordion behavior)
    this.expandedRowTargets.forEach(r => {
      if (r !== expandedRow && !r.classList.contains("hidden")) {
        r.classList.add("hidden")
        const otherCapId = r.dataset.capabilityId
        const otherRow = this.rowTargets.find(
          rt => rt.dataset.capabilityId === otherCapId
        )
        const otherChevron = otherRow?.querySelector("[data-matrix-target='rowChevron']")
        if (otherChevron) otherChevron.classList.remove("rotate-90")
      }
    })

    const isExpanding = expandedRow.classList.contains("hidden")
    expandedRow.classList.toggle("hidden")

    // Rotate chevron
    const chevron = row.querySelector("[data-matrix-target='rowChevron']")
    if (chevron) {
      chevron.classList.toggle("rotate-90", isExpanding)
    }

    // Dim sibling rows when a row is expanded (visual focus)
    this.#updateRowDimming(isExpanding ? capId : null)

    // Dispatch focus change. URL sync (capability + level_ordinal)
    // happens centrally inside #setFocus.
    if (isExpanding) {
      const categoryId = this.#categoryIdForRow(row)
      this.#setFocus({
        level: "capability",
        categoryId: categoryId,
        capabilityId: capId,
        capabilityStableId: row.dataset.capabilityStableId || null,
        levelOrdinal: null,
        expectationId: null
      })
      // Anchor the capability's *top* (the compact row) just below the
      // sticky chrome so expanding never scrolls the viewport away from the
      // capability name. The compact row carries `scroll-mt` matching the
      // sticky column + category header height.
      this.#anchorCapabilityTop(row)
    } else {
      this.#setFocus({ level: "framework" })
    }
  }

  // Smoothly scrolls so the expanded `<tr>` is fully visible. Uses
  // `block: "nearest"` to avoid yanking the page when the row is
  // already onscreen, but ensures the expanded content's bottom edge
  // doesn't sit below the viewport.
  #anchorCapabilityTop(compactRow) {
    if (!compactRow) return
    // Defer to the next animation frame so the browser has applied the
    // layout change (un-hide the expanded row) before scrolling. `block:
    // "start"` aligns the compact row's top to the scrollport top; the
    // row's `scroll-mt` leaves room for the sticky column + category
    // headers so the capability name lands just beneath them.
    requestAnimationFrame(() => {
      compactRow.scrollIntoView({ behavior: "smooth", block: "start", inline: "nearest" })
    })
  }

  // ── Category focus ── (framework explorer)

  focusCategory(event) {
    event.stopPropagation()
    const target = event.currentTarget
    const categoryId = target.dataset.categoryId
    if (!categoryId) return

    // Toggle off if already focused on this category
    if (this.currentFocus.level === "category" &&
        this.currentFocus.categoryId === categoryId) {
      this.#setFocus({ level: "framework" })
      return
    }

    this.#setFocus({
      level: "category",
      categoryId: categoryId,
      capabilityId: null,
      levelOrdinal: null,
      expectationId: null
    })
  }

  // ── Cell focus ── (framework explorer, expanded-row cells)

  focusCell(event) {
    const cell = event.currentTarget
    const allowOnButton = cell.dataset.focusOnButtonClick === "true"
    const onInteractive = !!event.target.closest("button, a, input, textarea, form, [contenteditable]")

    // The framework explorer's expanded cells contain inline-editor
    // forms — focus must NOT fire when clicking the pencil/save/cancel
    // controls. The assessment cells opt-in to "focus even when the
    // click landed on the rating selector or evidence buttons" via
    // `data-focus-on-button-click="true"`, so a tap on a frequency
    // button both submits the rating AND focuses the cell.
    //
    // The unfocus close button always stops its own click first
    // (data-action="click->matrix#unfocusCell"), so it doesn't reach
    // here regardless of this guard.
    if (!allowOnButton && onInteractive) {
      return
    }

    event.stopPropagation()
    const capabilityId = cell.dataset.capabilityId
    const levelOrdinal = parseInt(cell.dataset.levelOrdinal, 10)
    const expectationId = cell.dataset.expectationId || null
    if (!capabilityId || isNaN(levelOrdinal)) return

    // Resolve the category from the row the cell belongs to — reusing
    // `this.currentFocus.categoryId` would leak a stale value when the user
    // focused on one category and then clicked a cell in another.
    const row = this.rowTargets.find(r => r.dataset.capabilityId === capabilityId)
    const categoryId = row ? this.#categoryIdForRow(row) : null

    const capabilityStableId = row?.dataset.capabilityStableId || cell.dataset.capabilityStableId || null

    const alreadyFocusedHere =
      this.currentFocus.level === "cell" &&
      this.currentFocus.capabilityId === capabilityId &&
      this.currentFocus.levelOrdinal === levelOrdinal

    // Toggle off only on a BACKGROUND click of the same cell, AND only
    // when the cell hasn't opted out via `data-bg-unfocus="false"`. The
    // framework explorer relies on background-click as its only exit
    // path (no per-cell close button exists there). Assessment cells
    // opt out because they render an explicit × close button — the
    // user expects clicking the evidence/illustration text inside an
    // already-focused cell to be a no-op, not to drop focus.
    //
    // A click on a button (rating selector, evidence affordance) inside
    // the focused cell never reaches this branch regardless — `onInteractive`
    // is true. Otherwise rating a cell would drop focus the moment the
    // rating lands.
    const allowBgUnfocus = cell.dataset.bgUnfocus !== "false"
    if (alreadyFocusedHere && !onInteractive && allowBgUnfocus) {
      this.#setFocus({
        level: "capability",
        categoryId: categoryId,
        capabilityId: capabilityId,
        capabilityStableId: capabilityStableId,
        levelOrdinal: null,
        expectationId: null
      })
      return
    }

    // Already focused here AND the click landed on an interactive
    // child — do nothing. The button/form runs its own action; we
    // don't need to re-dispatch the same focus state.
    if (alreadyFocusedHere) return

    // Compact-cell click: ensure the row is expanded so the focused
    // content (illustrations, evidence) is visible. No-op when already
    // expanded.
    this.#expandRow(capabilityId)

    this.#setFocus({
      level: "cell",
      categoryId: categoryId,
      capabilityId: capabilityId,
      capabilityStableId: capabilityStableId,
      levelOrdinal: levelOrdinal,
      expectationId: expectationId
    })
  }

  // ── Card-based capability focus (assessment card layout) ──

  // Click on a capability card's header sets capability-level focus
  // so the activity sidebar narrows to this capability. Toggles back
  // to category focus if the same card's header is re-clicked, mirroring
  // `focusCategory`'s behaviour at the category level.
  //
  // Suppresses scroll-driven capability detection for ~900ms so the
  // explicit click survives any in-flight scroll into-view animations
  // (the user landed on this card on purpose — don't let a scroll event
  // 200ms later overwrite their choice with whichever card now happens
  // to sit in the viewport band).
  focusCapability(event) {
    // Card-level click handlers must not fire when the user is
    // interacting with the level strip chips or any expansion-panel
    // controls (rating pill, evidence buttons, comment threads, inline
    // links). The chips and most expansion buttons already
    // `stopPropagation()`, but evidence/comment links and the pill
    // popover can bubble. The `card_header` only contains text, but
    // the contribution badge could theoretically host a focusable
    // child in future — guard defensively.
    const onInteractive = !!event.target.closest("button, a, input, textarea, form, [contenteditable]")
    if (onInteractive) return

    event.stopPropagation()
    const card = event.currentTarget.closest("[data-matrix-target='card']")
    if (!card) return
    const stableId = card.dataset.capabilityStableId
    const capabilityId = card.dataset.capabilityId
    if (!stableId) return

    const section = card.closest("section[data-category-id]")
    const categoryId = section?.dataset.categoryId || null

    // Suppress scroll-driven detection long enough for the click to
    // settle. Mirrors `category_nav_controller`'s 900ms window after
    // a chip click — without it, an IntersectionObserver callback
    // moments later could re-select a different card and overwrite
    // the user's explicit choice.
    this._capabilityFocusSuppressUntil = Date.now() + 1800

    const alreadyFocused =
      this.currentFocus.level === "capability" &&
      this.currentFocus.capabilityStableId === stableId

    if (alreadyFocused) {
      // Toggle off → category focus. Activity feed widens; the card's
      // data-focused attribute clears in #setFocus.
      this.#setFocus({
        level: "category",
        categoryId: categoryId,
        capabilityId: null,
        capabilityStableId: null,
        levelOrdinal: null,
        expectationId: null
      })
      return
    }

    this.#setFocus({
      level: "capability",
      categoryId: categoryId,
      capabilityId: capabilityId,
      capabilityStableId: stableId,
      levelOrdinal: null,
      expectationId: null
    })

    // Scroll the focused card under the sticky chrome. The click may
    // have landed anywhere on the page; the user expects the card they
    // focused to be the focal point afterwards. No frame reload to
    // wait for here — the scroll fires on the next animation frame
    // against the current DOM.
    this.#scrollCardUnderHeader(stableId, { awaitFrameLoad: false })
  }

  // ── Card-based chip focus (assessment card layout) ──

  focusChip(event) {
    event.stopPropagation()
    const chip = event.currentTarget
    const stableId = chip.dataset.capabilityStableId
    const ordinal = parseInt(chip.dataset.levelOrdinal, 10)
    if (!stableId || isNaN(ordinal)) return

    const alreadyFocused =
      this.currentFocus.level === "cell" &&
      this.currentFocus.capabilityStableId === stableId &&
      this.currentFocus.levelOrdinal === ordinal

    if (alreadyFocused) return

    const card = this.cardTargets.find(c => c.dataset.capabilityStableId === stableId)
    const categoryId = card?.closest("[data-category-id]")?.dataset.categoryId || null
    const capabilityId = card?.dataset.capabilityId || null

    // Suppress scroll-driven capability focus so the chip's smooth scroll
    // to the focused card doesn't get overridden by an intersecting
    // sibling mid-animation. Mirrors the suppression on `focusCapability`.
    this._capabilityFocusSuppressUntil = Date.now() + 1800

    // Dispatch focus immediately so the activity feed updates without
    // waiting for the matrix frame to round-trip.
    this.currentFocus = {
      level: "cell",
      categoryId,
      capabilityId,
      capabilityStableId: stableId,
      levelOrdinal: ordinal,
      expectationId: null
    }
    // Mirror the card ring stamping that `#setFocus` would do — this
    // path bypasses #setFocus to dispatch immediately before the matrix
    // frame round-trips.
    this.#applyCardFocus(stableId, "cell")
    this.#dispatchFocusEvent({ ...this.currentFocus })

    this.#reloadMatrixWithFocus(stableId, ordinal)
    this.#scrollCardUnderHeader(stableId)
  }

  // After a chip click reloads the matrix frame, scroll the capability
  // card to sit just below BOTH the unified sticky header AND the
  // capability's category section header (which is itself sticky and
  // pins underneath the unified header). Missing the category header
  // is the most common failure mode — the card top lands behind it.
  //
  // After the smooth scroll, a settle pass re-measures and corrects:
  // sticky-hero may compact during the animation, shifting the doc
  // layout by ~100px and leaving the original target stale. The
  // correction is a tiny instant scroll that snaps the card top to
  // exactly `header_bottom + 12` once everything has settled.
  // Card scroll-margin-top (in `capability_card.rb`) carries the offset
  // for the unified sticky chrome + the sticky section heading + a
  // 12px gap. `scrollIntoView({block: 'start'})` honours that, so the
  // card top lands flush below the chrome without manual math here.
  //
  // A settle pass re-scrolls instantly after the smooth animation
  // finishes — the hero collapses via a scroll-driven CSS animation
  // that runs in parallel with our smooth scroll, shifting the doc
  // layout mid-animation and letting the original landing drift. The
  // re-query guards against the original card node being detached
  // when the matrix turbo-frame replaced its content during the scroll.
  // Card scroll-margin-top (in `capability_card.rb`) carries the offset
  // for the unified sticky chrome + the sticky section heading + a
  // 12 px gap. We do the math explicitly here rather than relying on
  // scrollIntoView({block: "start"}): the browser's smooth animation
  // races with the hero's scroll-driven collapse, and scrollIntoView
  // does not retarget mid-flight when scroll-margin shifts. Doing the
  // arithmetic ourselves and snapping with `instant` after the smooth
  // animation lands the card top exactly at scroll-margin-top.
  // `awaitFrameLoad` — wait for the matrix turbo-frame's next
  // `turbo:frame-load` before scrolling. Used by `focusChip`, which
  // first reloads the frame; the scroll target's position is only
  // meaningful after the new DOM lands. Set false for paths that
  // don't reload (card-header click, URL deep-link on connect) so
  // the scroll fires on the next animation frame against the current
  // DOM instead of waiting for a frame-load that never arrives.
  #scrollCardUnderHeader(stableId, { awaitFrameLoad = true } = {}) {
    const frame = awaitFrameLoad
      ? (this.element.closest("turbo-frame") || this.element.querySelector("turbo-frame"))
      : null

    const findCard = () =>
      document.querySelector(`[data-matrix-target="card"][data-capability-stable-id="${stableId}"]`)

    // Override the card's static scroll-margin-top with one that also
    // includes the measured section heading height (varies per section
    // — descriptions wrap differently). Cards in different sections
    // would need different margins, so a single CSS rule can't cover
    // it; per-card inline override does.
    const applyScrollMargin = (card) => {
      const sectionH = card.closest("section[data-category-id]")
        ?.querySelector("[data-section-header]")?.offsetHeight || 0
      card.style.scrollMarginTop = `calc(var(--sticky-header-h, 0px) + ${sectionH + 12}px)`
    }

    const desiredTopFor = (card) => parseFloat(window.getComputedStyle(card).scrollMarginTop) || 0

    const scrollTo = (card, behavior) => {
      const cardTopDoc = card.getBoundingClientRect().top + window.scrollY
      const target = Math.max(0, cardTopDoc - desiredTopFor(card))
      window.scrollTo({ top: target, behavior })
    }

    const scroll = () => {
      const card = findCard()
      if (!card) return
      applyScrollMargin(card)
      scrollTo(card, "smooth")
      setTimeout(() => {
        const settled = findCard()
        if (!settled) return
        applyScrollMargin(settled)
        scrollTo(settled, "instant")
      }, 600)
    }

    if (frame) {
      frame.addEventListener("turbo:frame-load", scroll, { once: true })
    } else {
      requestAnimationFrame(scroll)
    }
  }

  #reloadMatrixWithFocus(stableId, ordinal) {
    const frame = this.element.closest("turbo-frame") ||
                  this.element.querySelector("turbo-frame")
    if (!frame) return

    const currentSrc = frame.getAttribute("src")
    if (!currentSrc) return

    let url
    try { url = new URL(currentSrc, window.location.origin) } catch { return }

    if (stableId) {
      url.searchParams.set("capability", stableId)
      url.searchParams.set("level_ordinal", ordinal.toString())
    } else {
      url.searchParams.delete("capability")
      url.searchParams.delete("level_ordinal")
    }

    frame.src = url.toString()

    // Sync browser URL
    const browserUrl = new URL(window.location)
    if (stableId) {
      browserUrl.searchParams.set("capability", stableId)
      browserUrl.searchParams.set("level_ordinal", ordinal.toString())
    } else {
      browserUrl.searchParams.delete("capability")
      browserUrl.searchParams.delete("level_ordinal")
    }
    window.history.pushState({}, "", browserUrl)
  }

  scrollToCategory(event) {
    event.preventDefault()
    const categoryId = event.currentTarget.dataset.categoryId
    if (!categoryId) return
    const section = document.getElementById(`category-${categoryId}`)
    if (!section) return

    const hero = document.getElementById("scoring-panel")
    const heroHeight = hero ? hero.offsetHeight : 0
    const sectionTop = section.getBoundingClientRect().top + window.scrollY
    window.scrollTo({ top: sectionTop - heroHeight - 16, behavior: "smooth" })
  }

  scrollToTop(event) {
    event.preventDefault()
    window.scrollTo({ top: 0, behavior: "smooth" })
  }

  // Window-scoped handler for the assessment:focus-unrated event
  // dispatched by the Continue Assessing button. The hero lives in
  // a different turbo frame so direct click->matrix actions can't
  // reach this controller.
  focusUnrated(event) {
    const { capabilityStableId, levelOrdinal } = event.detail || {}
    if (!capabilityStableId || typeof levelOrdinal !== "number") return

    this.currentFocus = {
      level: "cell",
      categoryId: null,
      capabilityId: null,
      capabilityStableId,
      levelOrdinal,
      expectationId: null
    }
    this.#dispatchFocusEvent({ ...this.currentFocus })
    this.#reloadMatrixWithFocus(capabilityStableId, levelOrdinal)
    // Land the *card* under the sticky chrome, not the chip centered in
    // viewport. A bare `chip.scrollIntoView({block: "center"})` is
    // sticky-chrome unaware — it puts the chip at viewport mid-height
    // but pushes the capability title above it up behind the sticky
    // header, so the user can't see what capability they just jumped
    // to. `#scrollCardUnderHeader` accounts for both the unified and
    // section-header heights and waits for the frame reload before
    // measuring.
    this.#scrollCardUnderHeader(capabilityStableId)
  }

  // ── Panel navigation ── (triggered by suggestion:navigate from context pane)

  navigateToEntity(event) {
    const {
      level, categoryId, capabilityId, capabilityStableId, levelOrdinal, expectationId
    } = event.detail || {}
    if (!level) return

    if (level === "framework") {
      this.#collapseAllRows()
      this.#setFocus({ level: "framework" })
      if (this.hasScrollContainerTarget) {
        this.scrollContainerTarget.scrollTo({ top: 0, left: 0, behavior: "smooth" })
      }
      return
    }

    if (level === "category") {
      this.#scrollToCategoryHeader(categoryId)
      this.#setFocus({ level: "category", categoryId })
      return
    }

    // capability or cell — expand the row and scroll to it. Match by
    // capability_id when present (framework explorer + same-version
    // assessment) and fall back to capability_stable_id (activity feed
    // entries are anchored to stable_id, never the per-version id).
    const row = this.rowTargets.find(r =>
      (capabilityId && r.dataset.capabilityId === capabilityId) ||
      (capabilityStableId && r.dataset.capabilityStableId === capabilityStableId)
    )

    // Row not in the current matrix DOM. In the assessment view this
    // means the entry's capability lives in another category tab —
    // navigate the matrix Turbo Frame to that tab and re-attempt the
    // expand once the new frame loads. Without this fallback, clicking
    // an activity-feed entry for a capability outside the active tab
    // would silently do nothing.
    if (!row) {
      if (categoryId && this.urlSyncValue) {
        this.#navigateToCategoryTab(categoryId, { capabilityStableId, levelOrdinal, level })
      }
      return
    }
    const resolvedCapabilityId = row.dataset.capabilityId
    const resolvedStableId = row.dataset.capabilityStableId || capabilityStableId

    // If the target row's category is collapsed (navigating from the
    // suggestions pane), reveal it first — otherwise the expand + scroll
    // land on a still-hidden row.
    this.#revealCategoryForRow(row)
    this.#expandRow(resolvedCapabilityId)

    row.scrollIntoView({ behavior: "smooth", block: "center" })

    if (level === "cell" && levelOrdinal != null) {
      this.#setFocus({
        level: "cell",
        categoryId: categoryId || this.#categoryIdForRow(row),
        capabilityId: resolvedCapabilityId,
        capabilityStableId: resolvedStableId,
        levelOrdinal,
        expectationId: expectationId || null
      })
    } else {
      this.#setFocus({
        level: "capability",
        categoryId: categoryId || this.#categoryIdForRow(row),
        capabilityId: resolvedCapabilityId,
        capabilityStableId: resolvedStableId
      })
    }
  }

  // ── Private ──

  // On connect, surface the matrix's implicit focus state. The
  // assessment matrix shows one category at a time, so an active
  // category tab IS a focus context — without dispatching here, the
  // activity feed wouldn't pick up tab changes (since each tab change
  // re-renders the frame and reconnects this controller). When a row
  // is already pre-expanded (deep-linked via ?capability=), we surface
  // capability-level focus instead — preserves what the page URL says
  // the user is looking at.
  #dispatchInitialFocus() {
    if (!this.activeCategoryIdValue) return

    // Source of truth for cell focus on connect: prefer the URL params
    // (capability + level_ordinal) when present, then fall back to the
    // server-rendered `data-focused-level-ordinal` on the expanded row.
    // This lets us restore focus even when the focused capability has
    // no illustrations/evidence (and therefore no server-rendered
    // expanded row to stamp the data attribute on).
    if (this.urlSyncValue) {
      const fromUrl = this.#focusFromUrl()
      if (fromUrl) {
        // Ensure the row is expanded so the focused content is
        // visible alongside the widened column.
        this.#expandRow(fromUrl.capabilityId)
        // Suppress scroll-driven re-picks for the animation window —
        // without this, the smooth scroll below would trip the scroll
        // observer mid-flight (the bar entering / leaving the viewport
        // band) and the area-based picker would overwrite the URL's
        // explicit choice with whichever card the eye lands on
        // intermediately during the scroll animation.
        this._capabilityFocusSuppressUntil = Date.now() + 1800
        this.#setFocus(fromUrl)
        // Reload deep-linked into a capability or cell — scroll the
        // focused card under the sticky chrome so the user lands on
        // it instead of at the top of the document. No frame reload
        // here (this is the initial connect path).
        if (fromUrl.capabilityStableId &&
            (fromUrl.level === "capability" || fromUrl.level === "cell")) {
          this.#scrollCardUnderHeader(fromUrl.capabilityStableId, { awaitFrameLoad: false })
        }
        return
      }
    }

    const expandedRow = this.expandedRowTargets.find(r => !r.classList.contains("hidden"))
    if (expandedRow) {
      const capabilityId = expandedRow.dataset.capabilityId
      const row = this.rowTargets.find(r => r.dataset.capabilityId === capabilityId)
      const focusedOrdinal = expandedRow.dataset.focusedLevelOrdinal
        ? parseInt(expandedRow.dataset.focusedLevelOrdinal, 10)
        : null
      const stableId = row?.dataset.capabilityStableId || expandedRow.dataset.capabilityStableId || null

      if (focusedOrdinal != null && !isNaN(focusedOrdinal)) {
        // Resolve expectation id from the matching <td> inside the
        // expanded row so the focus payload is fully populated on
        // initial connect (deep-link or post-broadcast reload).
        const cell = expandedRow.querySelector(`td[data-level-ordinal="${focusedOrdinal}"]`)
        this.#setFocus({
          level: "cell",
          categoryId: this.activeCategoryIdValue,
          capabilityId,
          capabilityStableId: stableId,
          levelOrdinal: focusedOrdinal,
          expectationId: cell?.dataset.expectationId || null
        })
        return
      }

      this.#setFocus({
        level: "capability",
        categoryId: this.activeCategoryIdValue,
        capabilityId: capabilityId,
        capabilityStableId: stableId,
        levelOrdinal: null,
        expectationId: null
      })
    } else {
      this.#setFocus({
        level: "category",
        categoryId: this.activeCategoryIdValue
      })
    }
  }

  // Builds a focus payload from the browser URL:
  //   `?capability=stable_id` alone → capability-level focus
  //   `?capability=` + `?level_ordinal=N`      → cell-level focus
  // Both shapes are restored on connect so reloads land back on the
  // user's last focused capability (sidebar narrows, ring stays put,
  // initial scroll lands on the focused card).
  //
  // Returns null when the URL carries no focus params.
  #focusFromUrl() {
    const url = new URL(window.location)
    const stableId = url.searchParams.get("capability")
    if (!stableId) return null

    const ordRaw = url.searchParams.get("level_ordinal")
    if (!ordRaw) {
      // Capability-level focus (no level_ordinal). Resolve the card OR
      // the row by stable_id so the rest of the payload is populated
      // exactly like the cell-level branch.
      const card = this.hasCardTarget &&
        this.cardTargets.find(c => c.dataset.capabilityStableId === stableId)
      if (card) {
        return {
          level: "capability",
          categoryId: card.closest("[data-category-id]")?.dataset.categoryId || this.activeCategoryIdValue,
          capabilityId: card.dataset.capabilityId || null,
          capabilityStableId: stableId,
          levelOrdinal: null,
          expectationId: null
        }
      }
      const row = this.rowTargets.find(r => r.dataset.capabilityStableId === stableId)
      if (!row) return null
      return {
        level: "capability",
        categoryId: this.activeCategoryIdValue || this.#categoryIdForRow(row),
        capabilityId: row.dataset.capabilityId,
        capabilityStableId: stableId,
        levelOrdinal: null,
        expectationId: null
      }
    }

    const ordinal = parseInt(ordRaw, 10)
    if (isNaN(ordinal)) return null

    // Card layout (assessment view) — chip element by ID; capability_id
    // comes from the wrapping card.
    const chip = document.getElementById(`cell-${stableId}-${ordinal}`)
    if (chip) {
      const card = this.cardTargets.find(c => c.dataset.capabilityStableId === stableId)
      return {
        level: "cell",
        categoryId: card?.closest("[data-category-id]")?.dataset.categoryId || this.activeCategoryIdValue,
        capabilityId: card?.dataset.capabilityId || null,
        capabilityStableId: stableId,
        levelOrdinal: ordinal,
        expectationId: null
      }
    }

    // Table layout (framework explorer) — fall back to row/<td> lookup.
    const row = this.rowTargets.find(r => r.dataset.capabilityStableId === stableId)
    if (!row) return null

    const capabilityId = row.dataset.capabilityId
    const cell = this.element.querySelector(
      `tr[data-matrix-target="row"][data-capability-id="${capabilityId}"] td[data-level-ordinal="${ordinal}"], ` +
      `tr[data-matrix-target="expandedRow"][data-capability-id="${capabilityId}"] td[data-level-ordinal="${ordinal}"]`
    )
    if (!cell) return null

    return {
      level: "cell",
      categoryId: this.activeCategoryIdValue || this.#categoryIdForRow(row),
      capabilityId,
      capabilityStableId: stableId,
      levelOrdinal: ordinal,
      expectationId: cell.dataset.expectationId || null
    }
  }

  // Dispatches matrix:focus-changed with a fully-specified detail payload.
  // Also resizes the table columns + toggles the per-cell close button when
  // entering / leaving cell-level focus (assessment view only — explorer
  // doesn't render <colgroup> so the col target list is empty there).
  //
  // `pushToUrl: false` opts out of `?capability=` / `?level_ordinal=`
  // URL sync entirely.
  //
  // `replaceUrl: true` updates the URL via `replaceState` instead of
  // `pushState` — used by the scroll-driven capability picker so
  // continuous scroll keeps the URL current (so reload restores the
  // focused capability) without thrashing the back-stack. Explicit
  // clicks (card header, level chip, suggestion pane navigation) push
  // so Back returns the user to their previous click.
  #setFocus({ level, categoryId = null, capabilityId = null, capabilityStableId = null,
              levelOrdinal = null, expectationId = null },
            { pushToUrl = true, replaceUrl = false } = {}) {
    this.currentFocus = {
      level, categoryId, capabilityId, capabilityStableId, levelOrdinal, expectationId
    }
    // Any explicit focus action that takes us off category clears the
    // sticky-category flag. The picker can resume normal capability
    // tracking after this. `#onExternalFocusChange` re-sets the flag
    // if the new focus is itself an external category dispatch.
    if (level !== "category") this._categoryFocusFromExternal = false
    this.#applyColumnFocus(level === "cell" ? levelOrdinal : null,
                           level === "cell" ? capabilityId : null)
    this.#applyCardFocus(capabilityStableId, level)
    if ((pushToUrl || replaceUrl) && this.urlSyncValue) {
      // Capability is part of the URL whenever a row is expanded — i.e.
      // for cell AND capability focus levels. For framework/category
      // focus, capability is cleared. Always use the stable_id so the
      // server's `expanded_capability_id` comparison resolves correctly.
      const capForUrl = (level === "cell" || level === "capability")
        ? capabilityStableId
        : null
      const ordForUrl = level === "cell" ? levelOrdinal : null
      this.#syncFocusToUrl(capForUrl, ordForUrl, { replace: replaceUrl })
    }
    this.#dispatchFocusEvent({ ...this.currentFocus })
  }

  // Picks up `matrix:focus-changed` events from external dispatchers
  // (e.g. `category_nav_controller` on a chip click). Updates our own
  // currentFocus to match and arms scroll-driven capability suppression
  // for the animation window.
  //
  // Self/external discrimination: `detail.source === "matrix"`
  // identifies events we dispatched from `#dispatchFocusEvent`; any
  // other source (today: category-nav, omitted; tomorrow: anything
  // else) is treated as external. Carrying source on the event
  // payload survives any future change in dispatch timing (queueMicrotask,
  // async wrappers) — a synchronous in-controller flag would not.
  #onExternalFocusChange(event) {
    const detail = event.detail || {}
    // Debug breadcrumbs so tests can verify the listener actually ran
    // (separate the "listener wasn't installed" failure mode from
    // the "listener ran but did the wrong thing" failure mode).
    this._lastExternalFocusAt = Date.now()
    this._lastExternalFocusDetail = detail
    if (!detail.level) return
    if (detail.source === "matrix") return

    // External focus events ride along with a programmatic scroll
    // (a category chip click in particular). Suppress scroll-driven
    // capability re-picks for the animation. Renew-on-scroll: every
    // scroll event during the animation keeps suppression alive;
    // when scroll events stop for 250ms the suppression releases.
    // Naturally tracks the actual animation duration regardless of
    // CI speed — a fixed time window was too brittle.
    this._suppressionScrollRenew = true
    this.#renewSuppressionUntilScrollStops()

    const same =
      this.currentFocus.level === detail.level &&
      this.currentFocus.categoryId === (detail.categoryId || null) &&
      this.currentFocus.capabilityStableId === (detail.capabilityStableId || null) &&
      this.currentFocus.levelOrdinal === (detail.levelOrdinal ?? null)
    if (same) return

    this.currentFocus = {
      level: detail.level,
      categoryId: detail.categoryId || null,
      capabilityId: detail.capabilityId || null,
      capabilityStableId: detail.capabilityStableId || null,
      levelOrdinal: detail.levelOrdinal ?? null,
      expectationId: detail.expectationId || null
    }
    // An external category dispatch (chip click) is a deliberate user
    // choice; mark it sticky so the post-animation picker doesn't
    // overwrite it with capability focus on whatever card the scroll
    // happened to land in front of.
    this._categoryFocusFromExternal = detail.level === "category"
    this.#applyCardFocus(detail.capabilityStableId || null, detail.level)
  }

  // Sets/extends the "external focus is still settling" suppression.
  // Called once when an external focus event arrives and again on
  // every subsequent scroll event for as long as the suppression is
  // active. When scroll events stop for 250ms the timer fires and
  // clears the suppression, letting the picker run again.
  #renewSuppressionUntilScrollStops() {
    if (this._scrollSettleTimer) clearTimeout(this._scrollSettleTimer)
    // 2000ms keeps suppression alive comfortably across any
    // animation duration — including smooth scrolls that fire
    // scroll events with sparse intervals (>500ms between frames
    // is rare but not impossible under load). Every renew resets
    // this, so a 16ms-cadence smooth scroll never lets the timer
    // expire; the only release path is "scroll events have stopped
    // for a full 2 seconds", which only happens when the animation
    // is genuinely done.
    this._scrollSettleTimer = setTimeout(() => {
      this._scrollSettleTimer = null
      this._suppressionScrollRenew = false
    }, 2000)
  }

  // Wraps `window.dispatchEvent("matrix:focus-changed")` so every
  // self-dispatch carries `source: "matrix"`. The external-focus
  // listener uses this field to skip our own dispatches — without
  // re-suppressing on every scroll-driven update.
  #dispatchFocusEvent(detail) {
    window.dispatchEvent(new CustomEvent("matrix:focus-changed", {
      detail: { ...detail, source: "matrix" }
    }))
  }

  // ── Scroll-driven capability focus ──

  // Sets up an IntersectionObserver that tracks which capability cards
  // are currently in the visible band below the sticky chrome. Whenever
  // the intersecting set changes, we re-pick the focused capability:
  // the card whose top is closest to the sticky-header bottom (but not
  // above it) becomes focused.
  //
  // Gating: scroll-driven changes never overwrite cell focus (an
  // explicit chip click), and respect the suppression window set by
  // explicit focus actions. Without the gate, scrolling past a focused
  // card would silently demote the user's chip-level focus.
  //
  // Card targets can come and go as Turbo Stream replacements land
  // inside the matrix frame. A small MutationObserver on the matrix
  // root re-syncs the observed set whenever cards are added or
  // removed — Stimulus' built-in cardTargets only reflects the current
  // state, not a change feed.
  #setupCapabilityScrollObserver() {
    if (typeof IntersectionObserver === "undefined") return
    if (!this.hasCardTarget) return

    const onIntersection = (entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          this._intersectingCards.add(entry.target)
        } else {
          this._intersectingCards.delete(entry.target)
        }
      })
      // Layout-shift-driven IO callbacks during a smooth scroll (the
      // CSS scroll-driven hero collapse rewrites positions even after
      // the scroll event has fired) keep the external-focus suppression
      // alive until the layout truly settles.
      if (this._suppressionScrollRenew) this.#renewSuppressionUntilScrollStops()
      // Picker is no longer scheduled from IO callbacks. With the
      // picker iterating `cardTargets` directly (not the IO-maintained
      // set), the IO doesn't need to drive picker re-runs. Genuine
      // user scrolls trigger the picker via `_onCapabilityScroll`;
      // a delayed IO callback after a programmatic scroll's
      // suppression has expired would otherwise fire the picker
      // against a layout the user didn't actually touch and stomp
      // on an explicit focus state.
    }

    // `rootMargin: 0` + `threshold: 0` fires only on viewport entry
    // and exit — exactly what we need the observer to maintain (which
    // cards are candidates). Area changes during continuous scroll
    // don't cross thresholds, so a scroll-event listener below drives
    // the area re-pick at frame rate (RAF-coalesced).
    this._capabilityIntersectionObserver = new IntersectionObserver(onIntersection, {
      root: null,
      rootMargin: "0px",
      threshold: 0
    })

    // Scroll-event-driven re-pick. The observer only fires on
    // entry/exit; during continuous scrolling between fixed sets of
    // intersecting cards (the common case), the picker won't run
    // again without this. RAF coalescing keeps it cheap.
    this._onCapabilityScroll = () => this.#scheduleCapabilityScrollUpdate()
    window.addEventListener("scroll", this._onCapabilityScroll, { passive: true })

    this.cardTargets.forEach(card => this._capabilityIntersectionObserver.observe(card))

    // Re-observe when cards are added (Turbo Stream replacement of the
    // matrix frame). Stimulus reconnects this controller on full frame
    // load, but partial Turbo Stream replacements within the frame
    // don't trigger reconnect. `observe(el)` is spec-defined as
    // idempotent, so we can call it on every card without tracking a
    // separate "already observed" set.
    this._cardListMutationObserver = new MutationObserver(() => {
      const live = new Set(this.cardTargets)
      live.forEach(card => this._capabilityIntersectionObserver.observe(card))
      this._intersectingCards.forEach(card => {
        if (!live.has(card)) this._intersectingCards.delete(card)
      })
    })
    this._cardListMutationObserver.observe(this.element, { childList: true, subtree: true })
  }

  #scheduleCapabilityScrollUpdate() {
    if (!this._capScrollRafId) {
      this._capScrollRafId = requestAnimationFrame(() => {
        this._capScrollRafId = null
        this.#updateFocusedCapabilityFromScroll()
      })
    }
    // Settle pass: re-run the picker ~250ms after the last scroll
    // event so the final landing position is what wins, not whichever
    // intermediate frame the RAF coalescer happened to land on. The
    // RAF path runs continuously so focus tracks scroll in real time;
    // this is the safety net for the last frame when scroll stops.
    //
    // Skipped while an external focus event is still settling — the
    // settle pass would otherwise fire immediately after `_suppressionScrollRenew`
    // releases and overwrite the explicit focus with whatever the
    // post-animation area winner is. Genuine user scrolls (no external
    // suppression in flight) keep the settle pass.
    if (this._suppressionScrollRenew) return
    if (this._capScrollSettleTimer) clearTimeout(this._capScrollSettleTimer)
    this._capScrollSettleTimer = setTimeout(() => {
      this._capScrollSettleTimer = null
      this.#updateFocusedCapabilityFromScroll()
    }, 250)
  }

  #updateFocusedCapabilityFromScroll() {
    if (Date.now() < this._capabilityFocusSuppressUntil) return
    // Renew-on-scroll suppression: external focus event is still
    // riding its smooth-scroll animation. See #renewSuppressionUntilScrollStops.
    if (this._suppressionScrollRenew) return
    // Don't auto-narrow on the observer's connect-time bootstrap. The
    // first IntersectionObserver callback fires with the cards' initial
    // intersection state — not in response to a user scroll. Acting on
    // it would silently override URL- and click-driven initial focus
    // and surprise the user (page load shouldn't make the activity
    // sidebar narrow on its own). Wait for at least one real scroll.
    if (!this._sawUserScroll) return
    if (!this.hasCardTarget) return

    const stickyH = this.#stickyHeaderHeight()
    const viewportH = window.innerHeight

    // Pick the card with the most visible area in the "content band" —
    // the viewport strip below the sticky chrome. Symmetric for scroll
    // up and down: the focused capability is always whichever card the
    // user has most of on screen.
    //
    // The previous "deepest card past sticky-chrome bottom" heuristic
    // was symmetric in mechanism but asymmetric in perception. Scrolling
    // DOWN, the trigger fired when the next card's top crossed the
    // chrome bottom — natural, since the new card was just appearing
    // there. Scrolling UP, the same trigger fired when the current
    // card's top crossed back below the chrome bottom, but at that
    // moment the "next" (returning) card could still be mostly off-
    // screen above, only its bottom edge peeking in. Focus would jump
    // to a card the user couldn't yet see. Area-based picking removes
    // the asymmetry entirely.
    //
    // Iterates `cardTargets` directly rather than the
    // IntersectionObserver-maintained `_intersectingCards` set so the
    // picker doesn't depend on IO callback timing. On slow CI runners
    // the IO callback can fire arbitrarily late, leaving the picker
    // with a stale (or empty) candidate set when the test asserts.
    // The IO is still useful as the scroll-event flusher (it triggers
    // `#scheduleCapabilityScrollUpdate`); it just isn't load-bearing
    // for which cards the picker considers.
    let best = null
    let bestArea = 0

    this.cardTargets.forEach(card => {
      const rect = card.getBoundingClientRect()
      const visibleTop = Math.max(rect.top, stickyH)
      const visibleBottom = Math.min(rect.bottom, viewportH)
      const area = Math.max(0, visibleBottom - visibleTop)
      if (area > bestArea) {
        bestArea = area
        best = card
      }
    })

    if (!best) return

    const stableId = best.dataset.capabilityStableId
    const capabilityId = best.dataset.capabilityId
    const categoryId = best.closest("section[data-category-id]")?.dataset.categoryId || null

    // Cell focus persists while the focused capability is still the
    // area-winner. The moment a different card takes over, cell focus
    // downgrades to capability focus on the new winner — the sidebar
    // re-narrows to whatever the user is now reading. Re-clicking a
    // chip restores cell focus.
    //
    // Capability focus is treated the same way: no re-dispatch when
    // the winner is unchanged.
    if (this.currentFocus.capabilityStableId === stableId &&
        (this.currentFocus.level === "cell" || this.currentFocus.level === "capability")) {
      return
    }

    // Category focus set externally (a chip click) is sticky — it
    // represents a deliberate user choice. The picker doesn't get to
    // downgrade it to capability focus from a scroll tick that fires
    // after the chip-click smooth scroll lands. The flag clears the
    // first time the user explicitly takes us off category (card
    // header / level chip click); after that, scroll-driven picks
    // resume normally.
    if (this.currentFocus.level === "category" && this._categoryFocusFromExternal) {
      return
    }

    // `replaceUrl: true` keeps `?capability=` current with the
    // scrolling-driven capability so a reload restores the focused
    // capability the user has scrolled to. Uses replaceState (not push)
    // so continuous scroll doesn't pile up history entries — Back
    // returns to the user's last explicit click, not every card they
    // scrolled past. The level_ordinal is implicitly cleared because
    // scroll-driven updates set `levelOrdinal: null`.
    this.#setFocus({
      level: "capability",
      categoryId,
      capabilityId,
      capabilityStableId: stableId,
      levelOrdinal: null,
      expectationId: null
    }, { pushToUrl: false, replaceUrl: true })
  }

  #stickyHeaderHeight() {
    const v = getComputedStyle(document.documentElement).getPropertyValue("--sticky-header-h")
    const n = parseFloat(v)
    return isNaN(n) ? 0 : n
  }

  // Stamps `data-focused="true"` on the currently-focused capability's
  // card and clears it on the previously-focused card. The ring +
  // shadow styling hangs off this attribute (see capability_card.rb's
  // data-variant classes), so the visual focus tracks any focus level
  // that includes a specific capability (capability OR cell). Framework-
  // and category-level focus clear the ring across every card.
  //
  // Diffs against `_focusedCard` so scroll-driven updates only touch
  // the two cards that actually changed — not every card on the page.
  // Iterating ~100 cardTargets per RAF tick during scroll otherwise
  // burns frames on attribute writes that the CSS data-variant selector
  // has to revalidate.
  #applyCardFocus(capabilityStableId, level) {
    if (!this.hasCardTarget) return
    const wantsRing = (level === "capability" || level === "cell") && !!capabilityStableId
    const next = wantsRing
      ? this.cardTargets.find(c => c.dataset.capabilityStableId === capabilityStableId)
      : null

    if (next === this._focusedCard) return

    if (this._focusedCard && this._focusedCard.isConnected) {
      this._focusedCard.dataset.focused = "false"
    }
    if (next) {
      next.dataset.focused = "true"
    }
    this._focusedCard = next
  }

  // ── Column focus (assessment cell-level) ──

  // Widens the focused level's column, narrows siblings, stamps
  // `data-focus-compact="true"` on every non-focused level cell so
  // AssessmentCell can degrade text density, and reveals the per-cell
  // close button only inside the focused expanded cell.
  //
  // Pass null for both args to reset everything to defaults.
  #applyColumnFocus(levelOrdinal, capabilityId) {
    if (!this.hasColTarget) return

    // Pick widths in pixels. Focused col widens to 32rem; siblings keep
    // the default 240px so the FrequencySelector's four buttons still
    // fit on a single row in non-focused cells. The fix is "additive":
    // focused gets wider, siblings stay the same width they had before
    // any cell was focused.
    //
    // We pin the table's total width to the sum of all col widths and
    // toggle table-layout: fixed so browsers honour each <col> exactly
    // instead of proportionally scaling them; the parent's
    // overflow-x-auto handles the horizontal scroll.
    const focusedWidthPx = 512   // 32rem
    const siblingWidthPx = 280   // matches default level col width
    const capabilityWidthPx = 220

    const levelCols = this.colTargets.filter(c => c.dataset.levelOrdinal !== "capability")

    this.colTargets.forEach(col => {
      const ord = col.dataset.levelOrdinal
      if (ord === "capability") return
      if (levelOrdinal == null) {
        col.style.width = ""
      } else if (Number(ord) === levelOrdinal) {
        col.style.width = `${focusedWidthPx}px`
      } else {
        col.style.width = `${siblingWidthPx}px`
      }
    })

    const table = this.colTargets[0]?.closest("table")
    if (table) {
      if (levelOrdinal == null) {
        // Default state: clear inline overrides so Tailwind's `w-full`
        // and the browser's default `table-layout: auto` drive sizing.
        // Auto-layout uses the FrequencySelector's intrinsic width as
        // each column's min, so cells stay wide enough for the rating
        // buttons regardless of how many levels the role has.
        table.style.width = ""
        table.style.tableLayout = ""
      } else {
        // Focus state: switch to `table-layout: fixed` so the explicit
        // <col> widths are honoured exactly, and pin the table's total
        // width to the sum so browsers don't proportionally scale the
        // cols when the sum overflows the container.
        table.style.tableLayout = "fixed"
        const tableWidth = capabilityWidthPx + focusedWidthPx +
                            (levelCols.length - 1) * siblingWidthPx
        table.style.width = `${tableWidth}px`
      }
    }

    // Compact every level <td> in non-focused columns so AssessmentCell
    // can degrade text density via Tailwind data variants.
    //
    // `data-focus-compact="true"` lands on every cell whose level
    // ordinal differs from the focused one — column-wide, regardless of
    // capability — because col widths are global to the column and all
    // cells in shrunken columns share the same density tweaks (see
    // FrequencySelector wrap behaviour).
    //
    // `data-focused="true"` is narrower: it lands ONLY on cells that
    // match BOTH the focused level ordinal AND the focused capability.
    // The expanded-cell illustration + evidence reveal hangs off this
    // attribute, so it must not leak to other rows' expanded cells —
    // even though their `<tr>`s are hidden, keeping the attribute scoped
    // to the visible focused cell keeps the semantics honest.
    this.element.querySelectorAll("td[data-level-ordinal]").forEach(td => {
      const ord = Number(td.dataset.levelOrdinal)
      const sameLevel = levelOrdinal != null && ord === levelOrdinal
      const sameCap = capabilityId != null && td.dataset.capabilityId === capabilityId

      if (levelOrdinal != null && !sameLevel) {
        td.dataset.focusCompact = "true"
      } else {
        delete td.dataset.focusCompact
      }

      if (sameLevel && sameCap) {
        td.dataset.focused = "true"
      } else {
        delete td.dataset.focused
      }
    })

    // Toggle the per-cell close button. Hidden everywhere except
    // inside the focused cell. The button lives in the COMPACT cell
    // (top-right corner of the rating area) so it stays anchored
    // where the user is looking, not buried in the illustration list.
    this.element.querySelectorAll("[data-focused-cell-close]").forEach(btn => btn.classList.add("hidden"))
    if (levelOrdinal != null && capabilityId != null) {
      const compactRow = this.rowTargets.find(r => r.dataset.capabilityId === capabilityId)
      const focusedCompact = compactRow?.querySelector(`td[data-level-ordinal="${levelOrdinal}"]`)
      if (focusedCompact) {
        const closeBtn = focusedCompact.querySelector("[data-focused-cell-close]")
        if (closeBtn) {
          closeBtn.classList.remove("hidden")
          closeBtn.classList.add("flex")
        }
      }

      // Scroll so both the compact cell + its expanded row are visible.
      // Vertical: bring the expanded row's bottom into view (or the
      // compact cell when no row is expanded). Horizontal: scroll the
      // matrix's overflow-x container so the focused cell sits to the
      // right of the STICKY capability column — `inline: "center"`
      // would land the cell behind the sticky cap when focusing the
      // first level. Defer to the next animation frame so the browser
      // computes positions against the post-resize layout.
      const expandedRow = this.element.querySelector(
        `tr[data-matrix-target="expandedRow"][data-capability-id="${capabilityId}"]`
      )
      const verticalAnchor = expandedRow && !expandedRow.classList.contains("hidden")
        ? expandedRow
        : focusedCompact
      if (verticalAnchor && focusedCompact) {
        requestAnimationFrame(() => {
          this.#scrollVertically(verticalAnchor)
          this.#scrollHorizontallyPastStickyCap(focusedCompact)
        })
      }
    }
  }

  #scrollVertically(target) {
    target.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "nearest" })
  }

  // Scrolls the matrix's `overflow-x-auto` wrapper so the focused cell
  // is fully visible AND not hidden behind the sticky-left capability
  // column. The cap column overlays everything to its right with
  // `position: sticky; left: 0`, so a naive `inline: "center"` (or
  // `inline: "start"`) for the first-level cell parks it directly
  // under the cap.
  #scrollHorizontallyPastStickyCap(cell) {
    const scroller = cell.closest(".overflow-x-auto")
    if (!scroller) return

    const cellRect = scroller.getBoundingClientRect && cell.getBoundingClientRect()
    const containerRect = scroller.getBoundingClientRect()
    const capCol = scroller.querySelector("col[data-level-ordinal='capability']")
    const capWidth = capCol?.getBoundingClientRect().width || 0

    const visibleLeft = containerRect.left + capWidth
    const leftDelta = cellRect.left - visibleLeft        // <0: hidden behind sticky cap
    const rightDelta = cellRect.right - containerRect.right // >0: extends past right edge

    let dx = 0
    if (leftDelta < 0) {
      // Cell is to the left of the visible area — scroll left to
      // expose it.
      dx = leftDelta
    } else if (rightDelta > 0) {
      // Cell extends past the right edge — scroll right, but never
      // far enough to push it back under the sticky cap (would
      // require more scroll than we have left-room).
      dx = Math.min(rightDelta, leftDelta)
    }

    if (dx !== 0) {
      scroller.scrollBy({ left: dx, behavior: "smooth" })
    }
  }

  // Public Stimulus action — explicit "exit focus" affordance rendered
  // top-right inside every expanded assessment cell. Brings focus back to
  // the capability level so the row stays expanded but the column resets.
  unfocusCell(event) {
    event.stopPropagation()
    const { categoryId, capabilityId, capabilityStableId } = this.currentFocus
    this.#setFocus({
      level: "capability",
      categoryId,
      capabilityId,
      capabilityStableId,
      levelOrdinal: null,
      expectationId: null
    })
  }

  // Walks back from a capability row to its category header to find the category id.
  #categoryIdForRow(row) {
    let sibling = row.previousElementSibling
    while (sibling) {
      if (sibling.dataset?.matrixTarget === "categoryHeader") {
        return sibling.dataset.categoryId || null
      }
      sibling = sibling.previousElementSibling
    }
    return null
  }

  #collapseAllRows() {
    this.expandedRowTargets.forEach(r => {
      if (!r.classList.contains("hidden")) {
        r.classList.add("hidden")
        const row = this.rowTargets.find(rt => rt.dataset.capabilityId === r.dataset.capabilityId)
        const chevron = row?.querySelector("[data-matrix-target='rowChevron']")
        if (chevron) chevron.classList.remove("rotate-90")
      }
    })
    this.#updateRowDimming(null)
  }

  // Programmatically expands a row by capability ID (accordion: collapses others).
  #expandRow(capId) {
    const expandedRow = this.expandedRowTargets.find(r => r.dataset.capabilityId === capId)
    if (!expandedRow) return

    // Already expanded — nothing to do
    if (!expandedRow.classList.contains("hidden")) return

    // Collapse any other expanded row (accordion)
    this.expandedRowTargets.forEach(r => {
      if (r !== expandedRow && !r.classList.contains("hidden")) {
        r.classList.add("hidden")
        const otherRow = this.rowTargets.find(rt => rt.dataset.capabilityId === r.dataset.capabilityId)
        const otherChevron = otherRow?.querySelector("[data-matrix-target='rowChevron']")
        if (otherChevron) otherChevron.classList.remove("rotate-90")
      }
    })

    expandedRow.classList.remove("hidden")
    const row = this.rowTargets.find(r => r.dataset.capabilityId === capId)
    const chevron = row?.querySelector("[data-matrix-target='rowChevron']")
    if (chevron) chevron.classList.add("rotate-90")

    this.#updateRowDimming(capId)
  }

  #scrollToCategoryHeader(categoryId) {
    const header = this.categoryHeaderTargets.find(h => h.dataset.categoryId === categoryId)
    if (header) header.scrollIntoView({ behavior: "smooth", block: "center" })
  }

  #categoryRows(headerRow) {
    const rows = []
    let sibling = headerRow.nextElementSibling

    while (sibling) {
      // Stop at next category header
      if (sibling.dataset?.matrixTarget === "categoryHeader") break
      rows.push(sibling)
      sibling = sibling.nextElementSibling
    }

    return rows
  }

  // Ensures the target row's category is uncollapsed so subsequent expand +
  // scroll operations operate on a visible node. No-op when the category is
  // already open.
  #revealCategoryForRow(row) {
    const categoryId = this.#categoryIdForRow(row)
    if (!categoryId) return

    const header = this.categoryHeaderTargets.find(h => h.dataset.categoryId === categoryId)
    if (!header) return

    this.#categoryRows(header).forEach(r => r.classList.remove("hidden"))

    const chevron = header.querySelector("[data-matrix-target='categoryChevron']")
    if (chevron) {
      chevron.classList.add("rotate-90")
      chevron.classList.remove("rotate-0")
    }
  }

  #updateBrowserUrl(roleIds, track, query = "") {
    const url = new URL(window.location)
    url.searchParams.delete("roles[]")
    roleIds.forEach(id => url.searchParams.append("roles[]", id))
    url.searchParams.set("track", track)
    if (query) url.searchParams.set("q", query)
    else url.searchParams.delete("q")
    window.history.pushState({}, "", url)
  }

  // ── Assessment URL Sync ──

  // Navigates the matrix Turbo Frame to the target category, including
  // the focused capability + level in the URL so the server-rendered
  // matrix arrives with that row pre-expanded — `expanded_capability_id`
  // does the work on the server side.
  //
  // Re-runs after the new frame loads aren't needed: the new connect
  // surfaces the focus via #dispatchInitialFocus from the URL params.
  #navigateToCategoryTab(categoryId, { capabilityStableId, levelOrdinal, level }) {
    const frame = this.element.closest("turbo-frame") ||
                  this.element.querySelector("turbo-frame")
    if (!frame) return

    const currentSrc = frame.getAttribute("src")
    if (!currentSrc) return

    let url
    try { url = new URL(currentSrc, window.location.origin) } catch { return }
    url.searchParams.set("category", categoryId)
    if (capabilityStableId) url.searchParams.set("capability", capabilityStableId)
    if (level === "cell" && levelOrdinal != null) {
      url.searchParams.set("level_ordinal", levelOrdinal.toString())
    }
    frame.src = url.toString()
  }

  #listenForFrameLoad() {
    this._frame = this.element.closest("turbo-frame") ||
                  this.element.querySelector("turbo-frame")
    if (!this._frame) return

    this._frameLoadHandler = () => {
      this.#syncFrameUrlToBrowser()
      this.#restoreRowDimming()
    }
    this._frame.addEventListener("turbo:frame-load", this._frameLoadHandler)
  }

  // After a Turbo Frame load (tab switch), update the browser URL to match.
  #syncFrameUrlToBrowser() {
    const frame = this.element.closest("turbo-frame") ||
                  this.element.querySelector("turbo-frame")
    if (!frame) return

    const frameSrc = frame.getAttribute("src")
    if (!frameSrc) return

    const frameUrl = new URL(frameSrc, window.location.origin)
    const browserUrl = new URL(window.location)

    // Only sync the active category from the frame's src — that's the
    // ONE param the server "owns" (set when the user clicks a category
    // tab and the frame fetches the new category). `capability` and
    // `level_ordinal` are owned by JS focus state via setFocus +
    // syncCapabilityToUrl/syncLevelOrdinalToUrl. Overwriting them
    // from the frame's src would clobber a recent focus change
    // whenever the frame finishes loading after the click.
    const category = frameUrl.searchParams.get("category")
    if (category) {
      browserUrl.searchParams.set("category", category)
    } else {
      browserUrl.searchParams.delete("category")
    }

    window.history.pushState({}, "", browserUrl)
  }

  // Batched URL sync for focus state. Updates capability + level_ordinal
  // in a single history entry so Back/Forward maps 1:1 to explicit
  // focus changes. No-ops when the URL already matches — important on
  // initial connect, which dispatches focus from already-correct URL
  // state and would otherwise pile up duplicate back-stack entries.
  //
  // `replace: true` swaps the current history entry instead of pushing
  // a new one — used by scroll-driven updates that fire continuously
  // and would otherwise spam history. Explicit click paths
  // (focusChip, focusCapability, focusCategory) push so Back returns
  // the user to their previous click.
  #syncFocusToUrl(capId, levelOrdinal, { replace = false } = {}) {
    const url = new URL(window.location)
    const desiredCap = capId || null
    const desiredOrd = levelOrdinal != null ? String(levelOrdinal) : null

    if (url.searchParams.get("capability") === desiredCap &&
        url.searchParams.get("level_ordinal") === desiredOrd) return

    if (desiredCap) url.searchParams.set("capability", desiredCap)
    else url.searchParams.delete("capability")

    if (desiredOrd != null) url.searchParams.set("level_ordinal", desiredOrd)
    else url.searchParams.delete("level_ordinal")

    if (replace) {
      window.history.replaceState({}, "", url)
    } else {
      window.history.pushState({}, "", url)
    }
  }

  // Dims sibling compact rows when a row is expanded for visual focus.
  #updateRowDimming(expandedCapId) {
    this.rowTargets.forEach(row => {
      if (expandedCapId && row.dataset.capabilityId !== expandedCapId) {
        row.classList.add("opacity-40")
      } else {
        row.classList.remove("opacity-40")
      }
    })
  }

  // Restores row dimming after a frame reload if a row is pre-expanded.
  #restoreRowDimming() {
    const expandedRow = this.expandedRowTargets.find(r => !r.classList.contains("hidden"))
    this.#updateRowDimming(expandedRow?.dataset.capabilityId || null)
  }
}

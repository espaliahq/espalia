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
                     "scrollContainer", "col"]
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
    super.disconnect()
  }

  // ── Selection Update (Turbo Frame) ── (framework explorer)

  updateSelection(event) {
    const { roleIds, track } = event.detail
    if (!this.hasFrameTarget || !this.basePathValue) return

    const url = new URL(this.basePathValue, window.location.origin)
    roleIds.forEach(id => url.searchParams.append("roles[]", id))
    url.searchParams.set("track", track)

    this.frameTarget.src = url.toString()

    // Update browser URL for shareability
    this.#updateBrowserUrl(roleIds, track)
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
      // Bring the freshly-expanded row + its expanded `<tr>` into
      // view. With Stimulus accordions, a row near the bottom of the
      // viewport can have its expanded content cut off — scroll the
      // expanded `<tr>` so its bottom edge is visible.
      this.#scrollExpandedRowIntoView(expandedRow)
    } else {
      this.#setFocus({ level: "framework" })
    }
  }

  // Smoothly scrolls so the expanded `<tr>` is fully visible. Uses
  // `block: "nearest"` to avoid yanking the page when the row is
  // already onscreen, but ensures the expanded content's bottom edge
  // doesn't sit below the viewport.
  #scrollExpandedRowIntoView(expandedRow) {
    if (!expandedRow) return
    // Defer to the next animation frame so the browser has a chance to
    // apply the layout change (un-hide the row, set col widths, etc.)
    // before computing scroll position.
    requestAnimationFrame(() => {
      expandedRow.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "nearest" })
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
        this.#setFocus(fromUrl)
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

  // Builds a cell-focus payload from the browser URL when both
  // `?capability=stable_id` and `?level_ordinal=N` are present AND we
  // can resolve a row matching the stable_id in the current DOM.
  // Returns null when the URL doesn't carry cell-focus params.
  #focusFromUrl() {
    const url = new URL(window.location)
    const stableId = url.searchParams.get("capability")
    const ordRaw = url.searchParams.get("level_ordinal")
    if (!stableId || !ordRaw) return null

    const ordinal = parseInt(ordRaw, 10)
    if (isNaN(ordinal)) return null

    const row = this.rowTargets.find(r => r.dataset.capabilityStableId === stableId)
    if (!row) return null

    const capabilityId = row.dataset.capabilityId
    const cell = this.element.querySelector(
      `tr[data-matrix-target="row"][data-capability-id="${capabilityId}"] td[data-level-ordinal="${ordinal}"], ` +
      `tr[data-matrix-target="expandedRow"][data-capability-id="${capabilityId}"] td[data-level-ordinal="${ordinal}"]`
    )
    // A stale `level_ordinal` (e.g. an old deep link to a level the
    // role no longer has) shouldn't short-circuit into cell focus
    // with no real cell behind it. Bail so dispatchInitialFocus's
    // capability/category fallback runs instead.
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
  #setFocus({ level, categoryId = null, capabilityId = null, capabilityStableId = null,
              levelOrdinal = null, expectationId = null }) {
    this.currentFocus = {
      level, categoryId, capabilityId, capabilityStableId, levelOrdinal, expectationId
    }
    this.#applyColumnFocus(level === "cell" ? levelOrdinal : null,
                           level === "cell" ? capabilityId : null)
    if (this.urlSyncValue) {
      // Capability is part of the URL whenever a row is expanded — i.e.
      // for cell AND capability focus levels. For framework/category
      // focus, capability is cleared. Always use the stable_id so the
      // server's `expanded_capability_id` comparison resolves correctly.
      const capForUrl = (level === "cell" || level === "capability")
        ? capabilityStableId
        : null
      const ordForUrl = level === "cell" ? levelOrdinal : null
      this.#syncFocusToUrl(capForUrl, ordForUrl)
    }
    window.dispatchEvent(new CustomEvent("matrix:focus-changed", {
      detail: { ...this.currentFocus }
    }))
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

  #updateBrowserUrl(roleIds, track) {
    const url = new URL(window.location)
    url.searchParams.delete("roles[]")
    roleIds.forEach(id => url.searchParams.append("roles[]", id))
    url.searchParams.set("track", track)
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

  // Batched URL sync for focus state. Pushes capability + level_ordinal
  // in a single history entry so Back/Forward maps 1:1 to visible
  // focus changes. No-ops when the URL already matches — important on
  // initial connect, which dispatches focus from already-correct URL
  // state and would otherwise pile up duplicate back-stack entries.
  #syncFocusToUrl(capId, levelOrdinal) {
    const url = new URL(window.location)
    const desiredCap = capId || null
    const desiredOrd = levelOrdinal != null ? String(levelOrdinal) : null

    if (url.searchParams.get("capability") === desiredCap &&
        url.searchParams.get("level_ordinal") === desiredOrd) return

    if (desiredCap) url.searchParams.set("capability", desiredCap)
    else url.searchParams.delete("capability")

    if (desiredOrd != null) url.searchParams.set("level_ordinal", desiredOrd)
    else url.searchParams.delete("level_ordinal")

    window.history.pushState({}, "", url)
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

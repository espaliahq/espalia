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
                     "scrollContainer"]
  static values = {
    basePath: String,
    urlSync: { type: Boolean, default: false }
  }

  connect() {
    super.connect()
    if (this.urlSyncValue) {
      this.#listenForFrameLoad()
    }
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
    const header = event.currentTarget
    const categoryId = header.dataset.categoryId
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

    // Sync browser URL with expanded capability
    if (this.urlSyncValue) {
      this.#syncCapabilityToUrl(isExpanding ? capId : null)
    }
  }

  // ── Private ──

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

  #updateBrowserUrl(roleIds, track) {
    const url = new URL(window.location)
    url.searchParams.delete("roles[]")
    roleIds.forEach(id => url.searchParams.append("roles[]", id))
    url.searchParams.set("track", track)
    window.history.pushState({}, "", url)
  }

  // ── Assessment URL Sync ──

  #listenForFrameLoad() {
    const frame = this.element.closest("turbo-frame") ||
                  this.element.querySelector("turbo-frame")
    if (!frame) return

    frame.addEventListener("turbo:frame-load", () => {
      this.#syncFrameUrlToBrowser()
      this.#restoreRowDimming()
    })
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

    const category = frameUrl.searchParams.get("category")
    const capability = frameUrl.searchParams.get("capability")

    if (category) {
      browserUrl.searchParams.set("category", category)
    } else {
      browserUrl.searchParams.delete("category")
    }

    if (capability) {
      browserUrl.searchParams.set("capability", capability)
    } else {
      browserUrl.searchParams.delete("capability")
    }

    window.history.pushState({}, "", browserUrl)
  }

  // Update capability param in browser URL on row toggle.
  #syncCapabilityToUrl(capId) {
    const url = new URL(window.location)
    if (capId) {
      url.searchParams.set("capability", capId)
    } else {
      url.searchParams.delete("capability")
    }
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

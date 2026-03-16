// Matrix controller for Turbo Frame updates and row/category expansion.
//
// Listens for tree:changed events to update the matrix Turbo Frame.
// Manages category collapse and row expansion within the matrix.
//
// <div data-controller="matrix"
//      data-matrix-base-path-value="/frameworks/abc/matrix"
//      data-action="tree:changed@window->matrix#updateSelection">
//   <turbo-frame id="framework-matrix" data-matrix-target="frame">
//     ...
//   </turbo-frame>
// </div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame", "row", "expandedRow",
                     "categoryHeader", "rowChevron", "categoryChevron",
                     "scrollContainer"]
  static values = {
    basePath: String
  }

  // ── Selection Update (Turbo Frame) ──

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

    const isExpanding = expandedRow.classList.contains("hidden")
    expandedRow.classList.toggle("hidden")

    // Rotate chevron
    const chevron = row.querySelector("[data-matrix-target='rowChevron']")
    if (chevron) {
      chevron.classList.toggle("rotate-90", isExpanding)
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
}

// The calibration comparison drawer's collapse toggle + clearance. The
// drawer is server-rendered and FIXED to the viewport bottom, so this
// controller keeps the host page padded by the drawer's real height —
// measured, so it tracks content and collapse, and applied on connect so
// it survives Turbo Frame swaps (a server-rendered class on the wrapper
// outside the frame could not). Collapse is remembered via a cookie.
//
// Example usage:
// <div data-controller="comparison-drawer">
//   <button data-action="comparison-drawer#toggle"
//           data-comparison-drawer-target="label">Collapse</button>
//   <div data-comparison-drawer-target="body">…cards…</div>
// </div>

import BaseController from "controllers/base_controller"

const COOKIE = "calibration_drawer_collapsed"

export default class extends BaseController {
  static targets = ["body", "label"]

  connect() {
    super.connect()
    if (this.#collapsed()) this.#apply(true)
    this.#pad()
  }

  disconnect() {
    // The drawer left with its frame (last card closed/unpinned) — release
    // the clearance so no dead scroll space remains.
    this.#host()?.style.removeProperty("padding-bottom")
    super.disconnect()
  }

  toggle() {
    const collapse = this.bodyTarget.style.display !== "none"
    this.#apply(collapse)
    document.cookie = `${COOKIE}=${collapse ? "1" : ""}; path=/; max-age=31536000; SameSite=Lax`
  }

  // private

  #apply(collapse) {
    this.bodyTarget.style.display = collapse ? "none" : ""
    this.labelTarget.textContent = collapse ? "Expand" : "Collapse"
    this.labelTarget.setAttribute("aria-expanded", collapse ? "false" : "true")
    this.#pad()
  }

  // Clearance = the drawer's measured height (+ breathing room), so page-end
  // content can always scroll above the fixed shelf — exact whether the
  // drawer holds one collapsed bar or three tall cards.
  #pad() {
    const host = this.#host()
    if (host) host.style.paddingBottom = `${this.element.offsetHeight + 16}px`
  }

  #host() {
    return document.querySelector("[data-drawer-host]")
  }

  #collapsed() {
    return document.cookie.split("; ").some(entry => entry === `${COOKIE}=1`)
  }
}

// The calibration comparison drawer's collapse toggle. The drawer itself
// is server-rendered (sticky bottom shelf); this only hides/shows the card
// row and remembers the choice for the session via a cookie, so a room
// that tucked the drawer away keeps it tucked across pane swaps.
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
  }

  #collapsed() {
    return document.cookie.split("; ").some(entry => entry === `${COOKIE}=1`)
  }
}

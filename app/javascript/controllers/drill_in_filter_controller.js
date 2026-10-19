// The capability drill-in's rater filter: a legend chip dims every other
// rater's marks, a second click clears it. The selection rides the URL
// (`?rater=`) so a shared link and every pane swap keep it; the server
// renders the same dimming, so this only has to follow clicks and Back.
//
// Example usage:
// <div data-controller="drill-in-filter" data-drill-in-filter-rater-value="">
//   <button type="button" aria-pressed="false"
//           data-action="drill-in-filter#toggle"
//           data-drill-in-filter-rater-param="<person id>">Raj Rater</button>
//   <a data-rater-id="<person id>">…</a>   <!-- "" for a rater not in the session -->
// </div>

import BaseController from "controllers/base_controller"

const DIM = "opacity-30"

export default class extends BaseController {
  static values = { rater: String }

  connect() {
    super.connect()
    this.onPopState = () => {
      this.raterValue = new URL(window.location.href).searchParams.get("rater") || ""
    }
    window.addEventListener("popstate", this.onPopState)
  }

  disconnect() {
    window.removeEventListener("popstate", this.onPopState)
    super.disconnect()
  }

  toggle({ params: { rater } }) {
    this.raterValue = this.raterValue === rater ? "" : rater

    const url = new URL(window.location.href)
    if (this.raterValue) {
      url.searchParams.set("rater", this.raterValue)
    } else {
      url.searchParams.delete("rater")
    }
    // A filter is not a navigation: replace, so Back still leaves the page.
    history.replaceState(history.state, "", url)
  }

  raterValueChanged() {
    const rater = this.raterValue
    this.element.querySelectorAll("[data-rater-id]").forEach((mark) => {
      mark.classList.toggle(DIM, rater !== "" && mark.dataset.raterId !== rater)
    })
    this.element.querySelectorAll("[data-drill-in-filter-rater-param]").forEach((chip) => {
      chip.setAttribute("aria-pressed", String(chip.dataset.drillInFilterRaterParam === rater))
    })
  }
}

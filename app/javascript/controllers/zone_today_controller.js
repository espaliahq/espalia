// Shows today's date in the zone picked, before it is saved.
// <div data-controller="zone-today">
//   <select data-zone-today-target="zone" data-action="zone-today#show">…</select>
//   <p data-zone-today-target="preview">It is <strong data-zone-today-target="date">…</strong> there today.</p>
//   <p data-zone-today-target="unknown" hidden>…</p>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["zone", "date", "preview", "unknown"]

  // A browser whose time zone data predates the zone throws, so it says the
  // date shows once saved rather than keep the last zone's.
  show() {
    let today
    try {
      today = new Intl.DateTimeFormat("en-GB", {
        timeZone: this.zoneTarget.value, weekday: "long", day: "numeric", month: "long", year: "numeric"
      }).format(new Date()).replace(",", "")
    } catch (error) {
      if (!(error instanceof RangeError)) throw error
    }
    if (today) this.dateTarget.textContent = today
    this.previewTarget.hidden = !today
    this.unknownTarget.hidden = !!today
  }
}

// Shows today's date in the zone picked, before it is saved.
// <div data-controller="zone-today">
//   <select data-zone-today-target="zone" data-action="zone-today#show">…</select>
//   <span data-zone-today-target="date">Tuesday 17 November 2026</span>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["zone", "date"]

  show() {
    this.dateTarget.textContent = new Intl.DateTimeFormat("en-GB", {
      timeZone: this.zoneTarget.value, weekday: "long", day: "numeric", month: "long", year: "numeric"
    }).format(new Date()).replace(",", "")
  }
}

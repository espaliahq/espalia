// "Load older activity" for the framework activity feed.
//
// On click, GETs the next (older) batch as a Turbo Stream — @rails/request.js
// applies the returned stream actions automatically: the older entries are
// appended to #framework-activity-list and this footer is replaced with the
// next cursor (or emptied when the feed is exhausted). No manual DOM work here.
//
// Usage:
//   <div data-controller="activity-more" data-activity-more-url-value="…?before=…">
//     <button data-action="activity-more#load" data-activity-more-target="button">
//       Load older activity
//     </button>
//   </div>

import BaseController from "controllers/base_controller"
import { get } from "@rails/request.js"

export default class extends BaseController {
  static values = { url: String }
  static targets = ["button"]

  async load() {
    if (this.hasButtonTarget) {
      this.buttonTarget.disabled = true
      this.buttonTarget.textContent = "Loading…"
    }
    // The Turbo Stream response appends the older entries, replaces this footer
    // (next cursor or empty), and replaces the header count with the new running
    // total — no client-side DOM work needed here.
    await get(this.urlValue, { responseKind: "turbo-stream" })
  }
}

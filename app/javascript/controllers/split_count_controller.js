// Names how many changes the split will take on its submit button, as boxes
// are ticked. The server draws the same label, so it reads right without
// JavaScript too.
//
// Usage:
//   <form data-controller="split-count" data-action="change->split-count#count">
//     <input type="checkbox" name="event_ids[]" data-split-count-target="box">
//     <button type="submit" data-split-count-target="label">Split off 1 change</button>
//   </form>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["box", "label"]

  connect() {
    super.connect()
    this.count()
  }

  count() {
    const chosen = this.boxTargets.filter((box) => box.checked).length
    this.labelTarget.textContent = this.constructor.label(chosen)
  }

  static label(chosen) {
    if (chosen === 0) return "Split off the chosen changes"
    return `Split off ${chosen} ${chosen === 1 ? "change" : "changes"}`
  }
}

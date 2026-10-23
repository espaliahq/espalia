// Greys out a list of type checkboxes while its "All types" box is ticked.
//
// The server lets "all" win whatever else is posted, so this only shows the
// admin what will happen: while All is ticked the type boxes read as ticked and
// cannot be changed. Unticking All gives back the choice they held before.
//
// Usage:
//   <div data-controller="all-kinds">
//     <input type="checkbox" value="all" data-all-kinds-target="all" data-action="all-kinds#sync">
//     <input type="checkbox" value="impact" data-all-kinds-target="kind">
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["all", "kind"]

  connect() {
    super.connect()
    this.sync()
  }

  sync() {
    const all = this.allTarget.checked

    this.kindTargets.forEach((box) => {
      if (all && !box.disabled) {
        box.dataset.chosen = box.checked
        box.checked = true
      } else if (!all && box.disabled && "chosen" in box.dataset) {
        box.checked = box.dataset.chosen === "true"
        delete box.dataset.chosen
      }
      box.disabled = all
    })
  }
}

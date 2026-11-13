// Sends one chosen date with whichever form inside it is submitted: each
// form carries a hidden `effective_on`, set to today on the server, and this
// copies the date field into it as the form goes.
//
// <div data-controller="effective-date" data-action="submit->effective-date#stamp">
//   <input type="date" data-effective-date-target="date">
//   <form>… <input type="hidden" name="effective_on"> …</form>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["date"]

  stamp(event) {
    const field = event.target.querySelector("input[name='effective_on']")
    if (field && this.dateTarget.value) field.value = this.dateTarget.value
  }
}

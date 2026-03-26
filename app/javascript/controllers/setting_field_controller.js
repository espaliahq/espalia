// Manages a single setting field with reset-to-default functionality.
//
// Usage:
// <div data-controller="setting-field"
//      data-setting-field-default-value="1.15">
//   <input type="number" data-setting-field-target="input"
//          data-action="input->setting-field#checkDefault">
//   <button type="button" data-setting-field-target="reset"
//           data-action="setting-field#reset">
//     Reset to default (1.15)
//   </button>
// </div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "reset"]
  static values = { default: String }

  connect() {
    this.checkDefault()
  }

  checkDefault() {
    const isDefault = this.inputTarget.value === this.defaultValue
    this.resetTarget.classList.toggle("hidden", isDefault)
  }

  reset() {
    this.inputTarget.value = this.defaultValue
    this.checkDefault()
  }
}

// Inline editor controller for editing text content in place.
//
// Toggles between a read-mode display and an edit-mode form. The form
// is a standard HTML form inside a <turbo-frame>, so Turbo intercepts
// the submission natively — no custom fetch needed.
//
// Usage:
//   <li data-controller="inline-editor">
//     <div data-inline-editor-target="display">
//       <span>Current text</span>
//       <button data-action="inline-editor#startEdit">Edit</button>
//     </div>
//     <form method="post" data-inline-editor-target="form" class="hidden">
//       <input type="hidden" name="_method" value="patch">
//       <textarea data-inline-editor-target="input">Current text</textarea>
//       <button type="submit">Save</button>
//       <button type="button" data-action="inline-editor#cancel">Cancel</button>
//     </form>
//   </li>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["display", "form", "input"]

  startEdit() {
    this.displayTarget.classList.add("hidden")
    this.formTarget.classList.remove("hidden")
    this.inputTarget.focus()
    // Place cursor at end of text
    const len = this.inputTarget.value.length
    this.inputTarget.setSelectionRange(len, len)
  }

  cancel() {
    // Reset textarea to original value before hiding
    this.inputTarget.value = this.inputTarget.defaultValue
    this.formTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
  }
}

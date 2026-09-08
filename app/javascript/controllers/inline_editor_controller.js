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

import BaseController from "controllers/base_controller"

// BaseController stamps `data-connected` on connect — the readiness signal
// system tests wait on before dispatching the pencil click (the editor is
// inserted late by the on-demand expanded row, so a click can otherwise land
// before the action handler exists).
export default class extends BaseController {
  static targets = ["display", "form", "input"]

  startEdit() {
    this.displayTarget.classList.add("hidden")
    this.formTarget.classList.remove("hidden")
    this.inputTarget.focus()
    // Place cursor at end of text — but only for text-like inputs.
    // <input type="date"> throws InvalidStateError; <select> has no
    // setSelectionRange. Guard with a try/catch so the editor still
    // works for non-text inputs (cycle type radio, planned end date).
    if (typeof this.inputTarget.setSelectionRange === "function") {
      try {
        const len = this.inputTarget.value.length
        this.inputTarget.setSelectionRange(len, len)
      } catch (_e) {
        // Input type doesn't support text-range selection; ignore.
      }
    }
  }

  cancel() {
    // Reset input/textarea to original value before hiding. defaultValue
    // is the initial server-rendered value for text inputs and textareas;
    // for selects we re-derive from each option's defaultSelected.
    if (this.inputTarget.tagName === "SELECT") {
      Array.from(this.inputTarget.options).forEach((opt) => {
        opt.selected = opt.defaultSelected
      })
    } else if ("defaultValue" in this.inputTarget) {
      this.inputTarget.value = this.inputTarget.defaultValue
    }
    this.formTarget.classList.add("hidden")
    this.displayTarget.classList.remove("hidden")
  }

  // Fired from `data-action="turbo:submit-end->inline-editor#submitted"` on
  // each inline-edit form. Dispatches a window-scoped `suggestion:submitted`
  // event so the context pane (which isn't a DOM ancestor of the form) can
  // reload its turbo frame and surface the fresh pending-suggestion row.
  submitted(event) {
    if (!event.detail.success) return

    window.dispatchEvent(new CustomEvent("suggestion:submitted", {
      bubbles: true,
      detail: { formAction: event.target.action }
    }))
  }
}

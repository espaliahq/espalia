// Keeps one user action to one request (audit issue #335). A Turbo form whose
// submit button is never disabled will happily fire a second POST on a
// double-click — observed on the evidence modal, where only write idempotency
// kept the duplicate harmless.
//
// Mount ON the form. While a submission is in flight the submit button is
// disabled and reads its in-flight label (its width is pinned first, so the
// footer doesn't jump), and any further `submit` event is stopped before it
// reaches Turbo's document-level listener — covering programmatic
// `requestSubmit()` as well as clicks.
//
// Both are released on `turbo:submit-end` regardless of outcome: a validation
// error keeps the modal open for another attempt, and a form the user can no
// longer submit would be a worse bug than the double POST.
//
// Usage:
//   <form data-controller="submit-guard"
//         data-action="submit->submit-guard#guard
//                      turbo:submit-start->submit-guard#start
//                      turbo:submit-end->submit-guard#end">
//     <button type="submit" data-submit-guard-target="button">Save</button>
//   </form>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["button"]
  static values = { label: { type: String, default: "Saving…" } }

  // Runs on the form in the bubble phase, ahead of Turbo's document-level
  // submit listener — so stopping propagation here stops the request too.
  guard(event) {
    if (!this.submitting) return
    event.preventDefault()
    event.stopImmediatePropagation()
  }

  start() {
    this.submitting = true
    if (!this.hasButtonTarget) return
    const button = this.buttonTarget
    this.originalLabel = button.textContent
    // Pin the resting width before the label shrinks to "Saving…".
    button.style.minWidth = `${button.offsetWidth}px`
    button.textContent = this.labelValue
    button.disabled = true
  }

  end() {
    this.submitting = false
    if (!this.hasButtonTarget) return
    const button = this.buttonTarget
    button.disabled = false
    if (this.originalLabel != null) button.textContent = this.originalLabel
  }
}

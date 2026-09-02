// Keeps one user action to one request (audit issue #335) by blocking a
// re-entrant submit while one is in flight — and does nothing else, because
// Turbo already does the rest.
//
// What Turbo gives us for free (verified in turbo-rails 2.0.23, nothing in
// this app overrides it):
//   - `config.forms.submitter` defaults to "disabled", so `requestStarted`
//     disables the submitter and `requestFinished` re-enables it whatever the
//     outcome — including a validation error, which must stay retryable.
//   - `data-turbo-submits-with` swaps the submitter's label for the duration
//     (`setSubmitsWith`) and restores it on the same hooks
//     (`resetSubmitterText`).
// Hand-rolling those two here bought two bugs and no behaviour: `end()` never
// cleared the `style.minWidth` it pinned, and a same-task double
// `requestSubmit()` captured "Saving…" as the "original" label and left it
// stuck on the button.
//
// What Turbo does NOT do is stop a SECOND submit event. A disabled button
// blocks the click path only — `form.requestSubmit()` sails straight past it
// to Turbo's document-level submit listener. `guard` stops that on the form,
// in the bubble phase, ahead of Turbo.
//
// Known edge: two submits in the SAME task both run before
// `turbo:submit-start` fires, so the guard is only armed from the second task
// onward. Turbo's navigator aborts the in-flight submission when the second
// one lands, so one request still reaches the server either way.
//
// Usage:
//   <form data-controller="submit-guard"
//         data-action="submit->submit-guard#guard
//                      turbo:submit-start->submit-guard#start
//                      turbo:submit-end->submit-guard#end">
//     <button type="submit" data-turbo-submits-with="Saving…">Save</button>
//   </form>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  // Runs on the form in the bubble phase, ahead of Turbo's document-level
  // submit listener — so stopping propagation here stops the request too.
  guard(event) {
    if (!this.submitting) return
    event.preventDefault()
    event.stopImmediatePropagation()
  }

  start() {
    this.submitting = true
  }

  end() {
    this.submitting = false
  }
}

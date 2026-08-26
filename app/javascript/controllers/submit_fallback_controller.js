// Surfaces transport-level Turbo submit failures that would otherwise be
// silent (audit issue #316). Domain errors already come back as rendered
// Turbo Stream responses; this controller covers the layer beneath them —
// a 5xx serving a non-stream body, or the network failing outright — where
// Turbo renders nothing and the user cannot tell "saved" from "failed".
//
// Mount on any element that CONTAINS the Turbo form(s) to protect, with a
// pre-existing empty live region as the message target (4.1.3 — the region
// must exist before text is injected):
//
// <div data-controller="submit-fallback"
//      data-action="turbo:before-fetch-response->submit-fallback#beforeFetchResponse
//                   turbo:submit-start->submit-fallback#submitStart
//                   turbo:submit-end->submit-fallback#submitEnd">
//   <form ...>…</form>
//   <div data-submit-fallback-target="message" role="alert" hidden></div>
// </div>
//
// beforeFetchResponse claims non-stream error responses (preventDefault =
// "custom handling") so Turbo Drive never renders a 5xx HTML body as the
// page — which would destroy the very form the user just filled.
//
// The message clears the moment a retry starts and on any success, so it can
// never describe a stale failure.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["message"]
  static values = {
    text: { type: String, default: "Couldn't save — check your connection and try again." },
    rejectedText: {
      type: String,
      default: "Couldn't save — the page may be out of date. Reload and try again."
    }
  }

  submitStart() {
    this.#hideMessage()
  }

  // Claims error responses Turbo would otherwise render as a full page
  // (5xx/4xx with an HTML body). A turbo-stream error response is left for
  // Turbo — the server rendered its own error UI (e.g. the rating
  // domain-error partial).
  beforeFetchResponse(event) {
    // Only claim FORM submissions — a failed turbo-frame LOAD (e.g. the lazy
    // modal frame's GET erroring) must keep Turbo's own frame error handling,
    // and "couldn't save" would be a wrong message for a page that never
    // loaded.
    if (!(event.target instanceof HTMLFormElement)) return
    const response = event.detail?.fetchResponse
    if (!response || response.succeeded) return
    const contentType = response.contentType || ""
    if (contentType.includes("vnd.turbo-stream")) return
    event.preventDefault()
    this.#showMessage(response)
  }

  submitEnd(event) {
    if (event.detail?.success) {
      this.#hideMessage()
      return
    }
    // A turbo-stream error response is the server speaking for itself
    // (e.g. the rating domain-error partial) — don't double-report.
    const contentType = event.detail?.fetchResponse?.contentType || ""
    if (contentType.includes("vnd.turbo-stream")) return
    this.#showMessage(event.detail?.fetchResponse)
  }

  // private

  // The connection copy is only honest for transport failures (no response
  // at all, or a 5xx). A 4xx is the app REJECTING the write — stale
  // permissions or state — where "try again" alone would invite retries
  // that can never succeed; "reload" is the recovery that actually works.
  #showMessage(response = null) {
    if (!this.hasMessageTarget) return
    const rejected = response && response.statusCode < 500
    this.messageTarget.textContent = rejected ? this.rejectedTextValue : this.textValue
    this.messageTarget.hidden = false
  }

  #hideMessage() {
    if (!this.hasMessageTarget) return
    this.messageTarget.textContent = ""
    this.messageTarget.hidden = true
  }
}

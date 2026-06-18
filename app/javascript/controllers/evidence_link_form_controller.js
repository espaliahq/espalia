// Evidence "link to another capability" modal controller.
//
// Mounted on the assessment page wrapper (alongside `evidence-form` and
// `activity-pane`) so the kebab "Link to another capability" buttons inside
// the matrix turbo-frame — which are NOT descendants of the modal — can
// drive open() via a single Stimulus action listener.
//
// Each kebab "Link" item carries:
//   data-evidence-link-form-evidence-id-param="<uuid>"
//   data-evidence-link-form-from-capability-stable-id-param="<uuid>"
//   data-evidence-link-form-from-level-ordinal-param="<n>"
//
// open() reads these directly from the trigger button's dataset (same
// approach as evidence_form_controller — sidesteps Stimulus's param
// naming/transformation quirks), primes the form's action URL to the right
// /assessments/:id/evidence/:id/add_link endpoint, and stamps the
// originating cell into hidden fields so the server re-renders the cell the
// user acted from after the link lands.
//
// This is a transactional modal: it is NOT dismissed by an outside click (that
// would discard the in-progress form by accident). It closes only via the ×
// button, Cancel, Esc (wired on the host element in the show views), or a
// successful submit.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = [
    "modal", "panel", "form", "capabilitySelect", "levelSelect",
    "fromCapabilityField", "fromLevelField"
  ]
  static values = { assessmentId: String }

  connect() {
    super.connect()
  }

  disconnect() {
    document.body.style.overflow = ""
    super.disconnect()
  }

  open(event) {
    const trigger = event.currentTarget
    this.returnFocusElement = trigger
    const ds = trigger?.dataset
    const evidenceId = ds?.evidenceLinkFormEvidenceIdParam
    if (!evidenceId) return

    if (this.hasFormTarget) {
      this.formTarget.action = this.#addLinkPath(evidenceId)
    }
    if (this.hasFromCapabilityFieldTarget) {
      this.fromCapabilityFieldTarget.value = ds.evidenceLinkFormFromCapabilityStableIdParam || ""
    }
    if (this.hasFromLevelFieldTarget) {
      this.fromLevelFieldTarget.value = ds.evidenceLinkFormFromLevelOrdinalParam || ""
    }
    this.show()
  }

  close() {
    this.hide()
  }

  // private

  show() {
    this.modalTarget.classList.remove("hidden")
    this.modalTarget.classList.add("flex")
    document.body.style.overflow = "hidden"
    const focusable = this.modalTarget.querySelector("select, textarea, input:not([type='hidden'])")
    focusable && focusable.focus()
  }

  hide() {
    this.modalTarget.classList.add("hidden")
    this.modalTarget.classList.remove("flex")
    document.body.style.overflow = ""
    this.returnFocusElement?.focus()
    this.returnFocusElement = null
  }

  #addLinkPath(evidenceId) {
    return `/assessments/${this.assessmentIdValue}/evidence/${evidenceId}/add_link`
  }
}

// Evidence relink modal controller.
//
// Mounted on the assessment page wrapper (alongside `evidence-form` and
// `activity-pane`) so the kebab "Relink" buttons inside the matrix
// turbo-frame — which are NOT descendants of the modal — can drive
// open() via a single Stimulus action listener.
//
// Each kebab Relink item carries:
//   data-evidence-relink-form-evidence-id-param="<uuid>"
//   data-evidence-relink-form-capability-stable-id-param="<uuid>"
//   data-evidence-relink-form-level-ordinal-param="<n>"
//
// open() reads these directly from the trigger button's dataset (same
// approach as evidence_form_controller — sidesteps Stimulus's param
// naming/transformation quirks) and primes the form's selects to the
// CURRENT location, the form's action URL to the right
// /assessments/:id/evidence/:id/relink endpoint, and a small "Currently
// at <cap · L<n>>" label inside the modal so the user can see where
// they're moving from.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["modal", "panel", "form", "capabilitySelect", "levelSelect", "currentLabel"]
  static values = { assessmentId: String }

  connect() {
    super.connect()
    this.boundClickOutside = this.clickOutside.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this.boundClickOutside, true)
    document.body.style.overflow = ""
    super.disconnect()
  }

  open(event) {
    const trigger = event.currentTarget
    this.returnFocusElement = trigger
    const evidenceId = trigger?.dataset?.evidenceRelinkFormEvidenceIdParam
    const capabilityStableId = trigger?.dataset?.evidenceRelinkFormCapabilityStableIdParam
    const levelOrdinal = trigger?.dataset?.evidenceRelinkFormLevelOrdinalParam
    if (!evidenceId) return

    if (this.hasFormTarget) {
      this.formTarget.action = this.#relinkPath(evidenceId)
    }
    if (this.hasCapabilitySelectTarget && capabilityStableId) {
      this.capabilitySelectTarget.value = capabilityStableId
    }
    if (this.hasLevelSelectTarget && levelOrdinal) {
      this.levelSelectTarget.value = levelOrdinal
    }
    if (this.hasCurrentLabelTarget) {
      this.currentLabelTarget.textContent = this.#currentLabel(capabilityStableId, levelOrdinal)
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
    queueMicrotask(() => {
      document.addEventListener("click", this.boundClickOutside, true)
    })
    const focusable = this.modalTarget.querySelector("select, textarea, input:not([type='hidden'])")
    focusable && focusable.focus()
  }

  hide() {
    this.modalTarget.classList.add("hidden")
    this.modalTarget.classList.remove("flex")
    document.body.style.overflow = ""
    document.removeEventListener("click", this.boundClickOutside, true)
    this.returnFocusElement?.focus()
    this.returnFocusElement = null
  }

  clickOutside(event) {
    const target = event.target
    if (!(target instanceof Element)) return
    if (this.panelTarget.contains(target)) return
    if (target.closest("[data-action*='evidence-relink-form#open']")) return
    this.hide()
  }

  #relinkPath(evidenceId) {
    return `/assessments/${this.assessmentIdValue}/evidence/${evidenceId}/relink`
  }

  // Renders "Currently at <Capability name> · L<n>" by reading the
  // option label out of the capability select target — saves us
  // round-tripping the capability name through a separate data attribute.
  #currentLabel(capabilityStableId, levelOrdinal) {
    if (!capabilityStableId || !levelOrdinal) return ""
    const opt = this.capabilitySelectTarget?.querySelector(`option[value='${capabilityStableId}']`)
    const name = opt ? opt.textContent.trim() : "this capability"
    return `Currently at ${name} · L${levelOrdinal}`
  }
}

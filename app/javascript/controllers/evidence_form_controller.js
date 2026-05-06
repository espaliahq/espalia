// Example usage:
// <div data-controller="evidence-form">
//   ...modal contents with form / hidden fields...
// </div>
//
// Triggered from the per-cell "+ Add evidence" button:
// <button data-action="click->evidence-form#open"
//         data-evidence-form-capability-stable-id-param="<uuid>"
//         data-evidence-form-level-ordinal-param="3">+ Add evidence</button>
//
// The controller hosts a single page-level modal repurposed for whichever
// (capability, level) cell triggered it, instead of rendering one modal
// per cell. Body scroll is locked while open.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["modal", "panel", "form", "capabilityField", "levelField", "typeSelect", "customLabelWrapper"]

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
    // Read coords directly from the trigger button's dataset rather than
    // event.params — keeps the contract independent of Stimulus's param
    // naming/transformation rules.
    const trigger = event.currentTarget
    const capabilityStableId = trigger?.dataset?.evidenceFormCapabilityStableIdParam
    const levelOrdinal = trigger?.dataset?.evidenceFormLevelOrdinalParam
    if (!capabilityStableId || levelOrdinal == null || levelOrdinal === "") return

    this.formTarget.reset()
    this.capabilityFieldTarget.value = capabilityStableId
    this.levelFieldTarget.value = levelOrdinal
    this.syncCustomLabel()
    this.show()
  }

  close() {
    this.hide()
  }

  typeChanged() {
    this.syncCustomLabel()
  }

  // private

  show() {
    this.modalTarget.classList.remove("hidden")
    this.modalTarget.classList.add("flex")
    document.body.style.overflow = "hidden"
    // Defer the click-outside listener so the same click event that opened
    // the modal (which originates outside the panel) doesn't immediately
    // close it again on the next listener pass.
    queueMicrotask(() => {
      document.addEventListener("click", this.boundClickOutside, true)
    })
    const focusable = this.modalTarget.querySelector("textarea, input:not([type='hidden'])")
    focusable && focusable.focus()
  }

  hide() {
    this.modalTarget.classList.add("hidden")
    this.modalTarget.classList.remove("flex")
    document.body.style.overflow = ""
    document.removeEventListener("click", this.boundClickOutside, true)
  }

  syncCustomLabel() {
    const isOther = this.typeSelectTarget.value === "other"
    this.customLabelWrapperTarget.classList.toggle("hidden", !isOther)
    const inputs = this.customLabelWrapperTarget.querySelectorAll("input")
    inputs.forEach((input) => { input.required = isOther })
  }

  clickOutside(event) {
    if (this.panelTarget.contains(event.target)) return
    // Ignore the trigger button itself — its own click is what opened us.
    if (event.target.closest("[data-action*='evidence-form#open']")) return
    this.hide()
  }
}

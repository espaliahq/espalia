// Evidence-specific companion to the generic `modal` controller.
//
// Visibility (open/close/click-outside/scroll-lock) lives in `modal`. This
// controller only prefills the shared evidence modal for whichever (capability,
// level) cell triggered it, and toggles the custom-label field by type.
//
// Mounted on the assessment page wrapper alongside `modal`:
//   <div data-controller="modal evidence-form"
//        data-action="modal:open@window->evidence-form#prefill">
//
// The per-cell trigger opens the shared modal and carries the coords:
//   <button data-action="click->modal#open"
//           data-evidence-form-capability-stable-id-param="<uuid>"
//           data-evidence-form-level-ordinal-param="3">+ Add evidence</button>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["form", "capabilityField", "levelField", "typeSelect", "customLabelWrapper"]

  // Reacts to the modal:open event the `modal` controller dispatches. Reads the
  // coords from the trigger's dataset (carried on event.detail.dataset). No-ops
  // for modal opens that aren't evidence (e.g. the delegation modal).
  prefill(event) {
    const dataset = event.detail?.dataset || {}
    const capabilityStableId = dataset.evidenceFormCapabilityStableIdParam
    const levelOrdinal = dataset.evidenceFormLevelOrdinalParam
    if (!capabilityStableId || levelOrdinal == null || levelOrdinal === "") return

    this.formTarget.reset()
    this.capabilityFieldTarget.value = capabilityStableId
    this.levelFieldTarget.value = levelOrdinal
    this.syncCustomLabel()
  }

  typeChanged() {
    this.syncCustomLabel()
  }

  // private

  syncCustomLabel() {
    const isOther = this.typeSelectTarget.value === "other"
    this.customLabelWrapperTarget.classList.toggle("hidden", !isOther)
    const inputs = this.customLabelWrapperTarget.querySelectorAll("input")
    inputs.forEach((input) => { input.required = isOther })
  }
}

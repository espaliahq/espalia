// Drives the "request evidence" modal.
//
// Two roles, same controller class (mirrors evidence_modal):
//   - PAGE instance (on the wrapper with `modal`): `load` points the lazy
//     `#evidence-request-modal` frame at the render endpoint for the clicked
//     cell, so the server renders the form with that cell's context + suggestions.
//   - IN-FRAME instance (on the rendered form): the search/add/remove picker
//     mechanics come from PersonPickerController (the shared control this
//     modal's picker was extracted into); this subclass adds the modal-frame
//     `load` and the send-count submit label.
//
// Usage (page trigger):
//   <button data-action="request-evidence#load click->modal#open"
//           data-modal-target-id="evidence-request-modal-overlay"
//           data-request-evidence-assignment-id-param="…"
//           data-request-evidence-capability-stable-id-param="…"
//           data-request-evidence-level-ordinal-param="3">Request evidence</button>

import PersonPickerController from "controllers/person_picker_controller"

export default class extends PersonPickerController {
  static targets = ["frame", "search", "results", "selected", "ids", "empty", "submit", "label", "suggestions"]
  static values = {
    candidatesUrl: String,
    fieldName: String,
    frameId: { type: String, default: "request-candidates" }
  }

  // PAGE: point the lazy frame at the assignment-scoped modal render endpoint.
  load(event) {
    if (!this.hasFrameTarget) return
    const p = event.params || {}
    if (!p.assignmentId) return
    const q = new URLSearchParams()
    if (p.capabilityStableId) q.set("capability_stable_id", p.capabilityStableId)
    if (p.levelOrdinal != null && p.levelOrdinal !== "") q.set("level_ordinal", p.levelOrdinal)
    this.frameTarget.src = `/assessments/${p.assignmentId}/evidence_request_modal?${q.toString()}`
  }

  // The evidence-request form predates the shared picker's field-name value —
  // keep the name hardcoded so the modal markup needs no changes.
  fieldName() {
    return "evidence_request[requestee_ids][]"
  }

  selectionChanged() {
    const n = this.selectedIds().length
    if (this.hasLabelTarget) this.labelTarget.textContent = n === 0 ? "Send requests" : `Send ${n} ${n === 1 ? "request" : "requests"}`
    if (this.hasSubmitTarget) this.submitTarget.disabled = n === 0
  }
}

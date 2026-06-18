// Evidence edit modal controller.
//
// Mounted on the assessment page wrapper (alongside `evidence-form` and
// `evidence-relink-form`). Kebab "Edit" buttons inside the matrix
// turbo-frame are sibling-cousins of this modal, not descendants, so
// the controller must enclose both — the show view wires this up.
//
// Each kebab Edit item carries:
//   data-evidence-edit-form-evidence-id-param="<uuid>"
//   data-evidence-edit-form-title-param="<string>"
//   data-evidence-edit-form-content-param="<string>"
//   data-evidence-edit-form-evidence-type-param="<string>"
//   data-evidence-edit-form-custom-type-label-param="<string>"
//   data-evidence-edit-form-ref-system-param="<string>"
//   data-evidence-edit-form-ref-url-param="<string>"
//
// open() reads them directly from the trigger's dataset (sidesteps
// Stimulus's param name transformation quirks — same approach as
// evidence_form_controller and evidence_relink_form_controller),
// stamps the form's action URL, prefills every field, and shows the
// modal. Submission is a PATCH (set via the form's `_method` hidden
// field) to /assessments/:assessment_id/evidence/:id.
//
// This is a transactional modal: it is NOT dismissed by an outside click (that
// would discard the in-progress edit by accident). It closes only via the ×
// button, Cancel, Esc (wired on the host element in the show views), or a
// successful submit.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = [
    "modal", "panel", "form",
    "typeSelect", "customLabelWrapper", "customLabelField",
    "titleField", "contentField",
    "refSystemField", "refUrlField"
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
    const evidenceId = ds?.evidenceEditFormEvidenceIdParam
    if (!evidenceId) return

    this.formTarget.action = this.#updatePath(evidenceId)

    this.typeSelectTarget.value = ds.evidenceEditFormEvidenceTypeParam || "project_outcome"
    this.customLabelFieldTarget.value = ds.evidenceEditFormCustomTypeLabelParam || ""
    this.titleFieldTarget.value = ds.evidenceEditFormTitleParam || ""
    this.contentFieldTarget.value = ds.evidenceEditFormContentParam || ""
    this.refSystemFieldTarget.value = ds.evidenceEditFormRefSystemParam || ""
    this.refUrlFieldTarget.value = ds.evidenceEditFormRefUrlParam || ""

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
    const focusable = this.modalTarget.querySelector("textarea, input:not([type='hidden']), select")
    focusable && focusable.focus()
  }

  hide() {
    this.modalTarget.classList.add("hidden")
    this.modalTarget.classList.remove("flex")
    document.body.style.overflow = ""
    this.returnFocusElement?.focus()
    this.returnFocusElement = null
  }

  syncCustomLabel() {
    const isOther = this.typeSelectTarget.value === "other"
    this.customLabelWrapperTarget.classList.toggle("hidden", !isOther)
    this.customLabelFieldTarget.required = isOther
  }

  #updatePath(evidenceId) {
    return `/assessments/${this.assessmentIdValue}/evidence/${evidenceId}`
  }
}

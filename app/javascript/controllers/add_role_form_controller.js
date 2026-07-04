// Prefills the shared role modal (new or edit mode) when its trigger opens it.
//
// On the window `modal:open` event it self-gates on the trigger dataset —
// `addRoleFamilyId` for a family's "+ Add role" row, `roleEditId` for the role
// row kebab's "Edit role…". New mode sets the hidden family id, shows the
// family name in the context line, clears name/code, and resets track to IC.
// Edit mode points the form at that role's update endpoint (path template with
// the id substituted) and prefills name/code/track from the dataset.
//
// On a successful edit submit it fires the window `org-structure:updated`
// event — the matrix listens and re-fetches, since a code/track change ripples
// through the header badges the tree-frame re-render can't reach. The current
// role selection is appended at submit time by the companion
// `tree-scope-fields` controller on the same form.
//
// Usage:
//   <form data-controller="add-role-form tree-scope-fields"
//         data-add-role-form-mode-value="new|edit"
//         data-add-role-form-action-template-value="/frameworks/F/roles/__RID__"
//         data-turbo-frame="role-tree-families"
//         data-action="turbo:submit-end->add-role-form#submitted
//                      turbo:submit-end->modal#submitted">
//     <input type="hidden" data-add-role-form-target="familyId"> <!-- new only -->
//     <span data-add-role-form-target="familyName"></span>       <!-- new only -->
//     <input data-add-role-form-target="name">
//     <input data-add-role-form-target="code">
//     <select data-add-role-form-target="track">…</select>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["familyId", "familyName", "name", "code", "track"]
  static values = {
    mode: { type: String, default: "new" },
    actionTemplate: String
  }

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  // The matrix header badges render role codes/tracks; the tree-frame
  // re-render can't touch them, so a successful edit asks the matrix to
  // re-fetch (same wiring shape as `suggestion:resolved` → matrix#refresh).
  submitted(event) {
    if (this.modeValue !== "edit") return
    if (event.detail?.success === false) return

    window.dispatchEvent(new CustomEvent("org-structure:updated"))
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}

    if (this.modeValue === "edit") {
      // Only respond to the role kebab's "Edit role…" trigger.
      if (data.roleEditId === undefined) return
      this.element.action = this.actionTemplateValue.replace("__RID__", data.roleEditId)
      if (this.hasNameTarget) this.nameTarget.value = data.roleEditName || ""
      if (this.hasCodeTarget) this.codeTarget.value = data.roleEditCode || ""
      if (this.hasTrackTarget) this.trackTarget.value = data.roleEditTrack || "ic"
    } else {
      // Only respond to "+ Add role" triggers (others share the modal:open bus).
      if (data.addRoleFamilyId === undefined) return
      if (this.hasFamilyIdTarget) this.familyIdTarget.value = data.addRoleFamilyId
      if (this.hasFamilyNameTarget) this.familyNameTarget.textContent = data.addRoleFamilyName || ""
      if (this.hasNameTarget) this.nameTarget.value = ""
      if (this.hasCodeTarget) this.codeTarget.value = ""
      // The select keeps its last value across opens — reset so a "Management"
      // pick for one family can't silently carry into the next.
      if (this.hasTrackTarget) this.trackTarget.value = "ic"
    }
  }
}

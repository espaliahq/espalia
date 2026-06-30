// Prefills the shared role-family edit modal from the role tree's hover "edit"
// trigger.
//
// On the window `modal:open` event it self-gates on `roleFamilyEditId`, points
// the form at that family's update endpoint (built from a path template with
// the id substituted), fills the name / description / department fields, and
// copies the current role selection (`roles[]` + `track`) from the browser URL
// into hidden inputs so the re-rendered tree keeps the selection checked.
//
// Usage:
//   <form data-controller="role-family-edit-form"
//         data-role-family-edit-form-action-template-value="/frameworks/F/role_families/__RFID__"
//         data-turbo-frame="role-tree-families"
//         data-action="turbo:submit-end->modal#submitted">
//     <div      data-role-family-edit-form-target="scope"></div>
//     <input    data-role-family-edit-form-target="name">
//     <textarea data-role-family-edit-form-target="description"></textarea>
//     <input    data-role-family-edit-form-target="department">
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["scope", "name", "description", "department"]
  static values = { actionTemplate: String }

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to role-family edit triggers (others share the modal:open bus).
    if (data.roleFamilyEditId === undefined) return

    this.element.action = this.actionTemplateValue.replace("__RFID__", data.roleFamilyEditId)

    if (this.hasNameTarget) this.nameTarget.value = data.roleFamilyEditName || ""
    if (this.hasDescriptionTarget) this.descriptionTarget.value = data.roleFamilyEditDescription || ""
    if (this.hasDepartmentTarget) this.departmentTarget.value = data.roleFamilyEditDepartment || ""

    this.#fillScope()
  }

  // Mirror the current role/track selection from the URL so the family-frame
  // re-render (which re-renders the whole tree, picking out the frame) keeps
  // the user's checkboxes checked.
  #fillScope() {
    if (!this.hasScopeTarget) return
    this.scopeTarget.replaceChildren()

    const params = new URLSearchParams(window.location.search)
    params.getAll("roles[]").forEach((roleId) => {
      this.scopeTarget.appendChild(this.#hiddenInput("roles[]", roleId))
    })
    const track = params.get("track")
    if (track) this.scopeTarget.appendChild(this.#hiddenInput("track", track))
  }

  #hiddenInput(name, value) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    return input
  }
}

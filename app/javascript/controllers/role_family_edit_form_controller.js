// Prefills the shared role-family modal (edit or new mode) when its trigger
// opens it.
//
// On the window `modal:open` event it self-gates on the trigger dataset —
// `roleFamilyEditId` for the edit dialog, `roleFamilyNew` for the tree-foot
// "+ Add role family" trigger. Edit mode points the form at that family's
// update endpoint (built from a path template with the id substituted) and
// fills the name / description / department fields; new mode clears them (the
// POST action is static). Both copy the current role selection (`roles[]` +
// `track`) from the browser URL into hidden inputs so the re-rendered tree
// keeps the selection checked.
//
// Usage:
//   <form data-controller="role-family-edit-form"
//         data-role-family-edit-form-mode-value="edit|new"
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
  static values = {
    actionTemplate: String,
    mode: { type: String, default: "edit" }
  }

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

    if (this.modeValue === "new") {
      // Only respond to the "+ Add role family" trigger.
      if (data.roleFamilyNew === undefined) return
      this.#fillFields({})
    } else {
      // Only respond to role-family edit triggers (others share the modal:open bus).
      if (data.roleFamilyEditId === undefined) return
      this.element.action = this.actionTemplateValue.replace("__RFID__", data.roleFamilyEditId)
      this.#fillFields({
        name: data.roleFamilyEditName,
        description: data.roleFamilyEditDescription,
        department: data.roleFamilyEditDepartment
      })
    }

    this.#fillScope()
  }

  #fillFields({ name, description, department }) {
    if (this.hasNameTarget) this.nameTarget.value = name || ""
    if (this.hasDescriptionTarget) this.descriptionTarget.value = description || ""
    if (this.hasDepartmentTarget) this.departmentTarget.value = department || ""
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

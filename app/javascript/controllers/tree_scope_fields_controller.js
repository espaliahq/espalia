// Appends the current role selection (roles[] + track, read from the browser
// URL that matrix_controller keeps in sync) to this form's submission at submit
// time, via the `formdata` event. Used by the department-rename inline editor so
// re-rendering the role-tree-families frame keeps the user's checkboxes checked.
//
// Submit-time (not connect-time) injection matters: the selection can change
// after the editor opens, and the formdata event fires exactly when Turbo builds
// the request body.
//
// Usage:
//   <form data-controller="tree-scope-fields" data-turbo-frame="role-tree-families">

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this._onFormData = this.#onFormData.bind(this)
    this.element.addEventListener("formdata", this._onFormData)
  }

  disconnect() {
    this.element.removeEventListener("formdata", this._onFormData)
  }

  // private

  #onFormData(event) {
    const params = new URLSearchParams(window.location.search)
    params.getAll("roles[]").forEach((roleId) => event.formData.append("roles[]", roleId))
    const track = params.get("track")
    if (track) event.formData.append("track", track)
  }
}

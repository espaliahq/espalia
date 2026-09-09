// Appends the current matrix scope (roles[] + track + the text filter q, read
// from the browser URL that matrix_controller keeps in sync) to this form's
// submission at submit time, via the `formdata` event.
//
// Two callers, one need: the department-rename inline editor re-renders the
// role-tree-families frame and must keep the user's checkboxes checked; every
// edit-mode write that answers a surgical Turbo Stream must re-render its rows
// against exactly the scope the grid around them was built with, or the
// streamed row silently disagrees with its neighbours.
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
    const query = params.get("q")
    if (query) event.formData.append("q", query)
  }
}

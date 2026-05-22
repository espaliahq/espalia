// Example usage:
// <form data-controller="collaborator-form"
//       data-collaborator-form-scope-picker-url-value="/tenant/users/:id/collaborator_scope_picker"
//       data-collaborator-form-scoped-roles-value='["role_lead", ...]'>
//   <select data-collaborator-form-target="frameworkSelect"
//           data-action="change->collaborator-form#refresh">...</select>
//   <select data-collaborator-form-target="roleSelect"
//           data-action="change->collaborator-form#refresh">...</select>
//   <div data-collaborator-form-target="scopeFrame">
//     <turbo-frame id="collaborator-scope-picker">...</turbo-frame>
//   </div>
// </form>
//
// Re-fetches the scope-entity picker Turbo Frame whenever the framework
// or role changes. Scoped roles need a framework-specific entity dropdown
// (role / role family / capability / category) populated server-side; the
// frame URL carries the chosen framework_id + role as query params.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["frameworkSelect", "roleSelect", "scopeFrame"]
  static values = {
    scopePickerUrl: String,
    scopedRoles: Array
  }

  refresh() {
    const role = this.roleSelectTarget.value
    const frameworkId = this.frameworkId()
    const frame = this.scopeFrameTarget.querySelector("turbo-frame#collaborator-scope-picker")
    if (!frame) return

    if (!this.isScoped(role) || !frameworkId) {
      // Framework-wide role or no framework picked — load an empty fragment.
      frame.src = this.buildUrl({ framework_id: frameworkId || "", role: role || "" })
      return
    }

    frame.src = this.buildUrl({ framework_id: frameworkId, role })
  }

  // private

  frameworkId() {
    if (this.hasFrameworkSelectTarget) return this.frameworkSelectTarget.value
    // When framework is locked, the assignment form carries a hidden input.
    const hidden = this.element.querySelector("input[name='collaborator[framework_id]']")
    return hidden ? hidden.value : ""
  }

  isScoped(role) {
    return this.scopedRolesValue.includes(role)
  }

  buildUrl(params) {
    const url = new URL(this.scopePickerUrlValue, window.location.origin)
    Object.entries(params).forEach(([k, v]) => url.searchParams.set(k, v))
    return url.toString()
  }
}

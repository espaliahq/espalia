// Framework Explorer shell controller.
//
// Manages the three-pane layout, including mobile role pane toggle.
//
// <div data-controller="framework-explorer">
//   <button data-action="framework-explorer#toggleRolePane">Roles</button>
//   <aside data-framework-explorer-target="rolePane">...</aside>
//   <aside data-framework-explorer-target="contextPane">...</aside>
// </div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rolePane", "contextPane"]

  toggleRolePane() {
    if (!this.hasRolePaneTarget) return

    this.rolePaneTarget.classList.toggle("hidden")
    this.rolePaneTarget.classList.toggle("lg:flex")

    // On mobile, show as overlay
    if (window.innerWidth < 1024) {
      this.rolePaneTarget.classList.toggle("absolute")
      this.rolePaneTarget.classList.toggle("inset-y-0")
      this.rolePaneTarget.classList.toggle("left-0")
      this.rolePaneTarget.classList.toggle("z-30")
    }
  }
}

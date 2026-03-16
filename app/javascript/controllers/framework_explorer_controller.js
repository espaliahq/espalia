// Framework Explorer shell controller.
//
// Manages the three-pane layout, including mobile role pane toggle.
// On mobile (< lg), the role pane is hidden via Tailwind's max-lg:hidden.
// The toggle button applies inline styles to override and show it as a
// fixed overlay. Clicking outside the overlay closes it.
//
// <div data-controller="framework-explorer">
//   <button data-action="framework-explorer#toggleRolePane">Roles</button>
//   <aside data-framework-explorer-target="rolePane"
//          class="max-lg:hidden ...">...</aside>
// </div>

import { Controller } from "@hotwired/stimulus"
import { useClickOutside } from "stimulus-use"

export default class extends Controller {
  static targets = ["rolePane", "contextPane"]

  connect() {
    this.rolePaneOpen = false
  }

  toggleRolePane() {
    if (!this.hasRolePaneTarget) return

    if (this.rolePaneOpen) {
      this.#closeRolePane()
    } else {
      this.#openRolePane()
    }
  }

  // Called by useClickOutside when clicking outside the role pane
  clickOutside(event) {
    if (!this.rolePaneOpen) return
    // Don't close if clicking the toggle button itself
    if (event.target.closest("[data-action*='toggleRolePane']")) return

    this.#closeRolePane()
  }

  // private

  #openRolePane() {
    this.rolePaneOpen = true
    Object.assign(this.rolePaneTarget.style, {
      display: "flex",
      position: "fixed",
      top: "0",
      left: "0",
      bottom: "0",
      zIndex: "30",
      width: "18rem"
    })
    // Activate click-outside detection on the role pane
    useClickOutside(this, { element: this.rolePaneTarget })
  }

  #closeRolePane() {
    this.rolePaneOpen = false
    this.rolePaneTarget.removeAttribute("style")
  }
}

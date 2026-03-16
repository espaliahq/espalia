// Framework Explorer shell controller.
//
// Manages the three-pane layout, including mobile role pane toggle.
// On mobile (< lg), the role pane is hidden via Tailwind's max-lg:hidden.
// The toggle button applies inline styles to override and show it as a
// fixed overlay, since class-based toggling can't reliably override
// responsive utility classes.
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

    this.rolePaneOpen = !this.rolePaneOpen

    if (this.rolePaneOpen) {
      // Override max-lg:hidden with inline styles for the overlay
      Object.assign(this.rolePaneTarget.style, {
        display: "flex",
        position: "fixed",
        top: "0",
        left: "0",
        bottom: "0",
        zIndex: "30",
        width: "18rem"
      })
    } else {
      // Remove inline styles to restore Tailwind responsive behaviour
      this.rolePaneTarget.removeAttribute("style")
    }
  }

  // Close role pane when clicking outside on mobile
  closeRolePane(event) {
    if (!this.rolePaneOpen || !this.hasRolePaneTarget) return
    if (this.rolePaneTarget.contains(event.target)) return

    this.rolePaneOpen = false
    this.rolePaneTarget.removeAttribute("style")
  }
}

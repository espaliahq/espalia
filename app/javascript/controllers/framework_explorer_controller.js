// Framework Explorer shell controller.
//
// Manages the three-pane layout and role pane toggle.
// On mobile (< lg): role pane shows as a fixed overlay, click-outside closes it.
// On desktop (lg+): role pane toggles inline visibility, no overlay.
//
// <div data-controller="framework-explorer">
//   <button data-action="framework-explorer#toggleRolePane"
//           data-framework-explorer-target="rolePaneToggle">
//     <svg data-framework-explorer-target="toggleChevron">...</svg>
//     4 Roles
//   </button>
//   <aside data-framework-explorer-target="rolePane"
//          class="max-lg:hidden ...">...</aside>
// </div>

import BaseController from "controllers/base_controller"
import { useClickOutside } from "stimulus-use"

export default class extends BaseController {
  static targets = ["rolePane", "contextPane", "rolePaneToggle", "toggleChevron",
                     "roleCount", "roleLabel", "contextPaneToggle"]

  connect() {
    super.connect()
    this.isMobile = window.innerWidth < 1024
    // On desktop the pane starts visible; on mobile it starts hidden
    this.rolePaneOpen = !this.isMobile
    // Read the context pane's initial open/closed state from the DOM. Edit
    // mode server-renders the pane with `flex` (open); view mode with
    // `hidden` (closed). Initialising from the rendered classes keeps the
    // toggle affordance in sync with what the user actually sees.
    this.contextPaneOpen = this.hasContextPaneTarget &&
      !this.contextPaneTarget.classList.contains("hidden")
    this.#updateToggleAffordance()
    this.#updateContextToggleAffordance()
  }

  toggleRolePane() {
    if (!this.hasRolePaneTarget) return

    this.isMobile = window.innerWidth < 1024

    if (this.rolePaneOpen) {
      this.#closeRolePane()
    } else {
      this.#openRolePane()
    }

    this.#updateToggleAffordance()
  }

  // Reveals the context pane when a squiggle click asks to show a suggestion
  // card (`suggestion:open-card` at window scope). Unlike focus changes —
  // which never auto-open the pane — this click's entire purpose is to see
  // the card, so a collapsed pane opens.
  openContextPane() {
    if (!this.hasContextPaneTarget || this.contextPaneOpen) return
    this.toggleContextPane()
  }

  toggleContextPane() {
    if (!this.hasContextPaneTarget) return

    this.contextPaneOpen = !this.contextPaneOpen
    if (this.contextPaneOpen) {
      this.contextPaneTarget.classList.remove("hidden")
      this.contextPaneTarget.classList.add("flex")
    } else {
      this.contextPaneTarget.classList.add("hidden")
      this.contextPaneTarget.classList.remove("flex")
    }

    this.#updateContextToggleAffordance()
  }

  // Update the role count display when selection changes
  updateRoleCount(event) {
    const { roleIds } = event.detail
    const count = roleIds.length

    if (this.hasRoleCountTarget) {
      this.roleCountTarget.textContent = count.toString()
    }
    if (this.hasRoleLabelTarget) {
      this.roleLabelTarget.textContent = ` Role${count === 1 ? "" : "s"}`
    }
  }

  // Called by useClickOutside when clicking outside the role pane
  clickOutside(event) {
    if (!this.rolePaneOpen) return
    if (event.target.closest("[data-action*='toggleRolePane']")) return

    this.#closeRolePane()
    this.#updateToggleAffordance()
  }

  // private

  #openRolePane() {
    this.rolePaneOpen = true

    if (this.isMobile) {
      Object.assign(this.rolePaneTarget.style, {
        display: "flex",
        position: "fixed",
        top: "0",
        left: "0",
        bottom: "0",
        zIndex: "30",
        width: "18rem"
      })
      useClickOutside(this, { element: this.rolePaneTarget })
    } else {
      this.rolePaneTarget.removeAttribute("style")
    }
  }

  #closeRolePane() {
    this.rolePaneOpen = false
    if (this.isMobile) {
      this.rolePaneTarget.removeAttribute("style")
    } else {
      this.rolePaneTarget.style.display = "none"
    }
  }

  #updateToggleAffordance() {
    // Rotate chevron: points down when closed, points up when open
    if (this.hasToggleChevronTarget) {
      this.toggleChevronTarget.classList.toggle("rotate-180", this.rolePaneOpen)
    }

    // Update toggle button active state
    if (this.hasRolePaneToggleTarget) {
      this.rolePaneToggleTarget.classList.toggle("bg-primary/10", this.rolePaneOpen)
      this.rolePaneToggleTarget.classList.toggle("text-primary", this.rolePaneOpen)
      this.rolePaneToggleTarget.classList.toggle("bg-gray-100", !this.rolePaneOpen)
      this.rolePaneToggleTarget.classList.toggle("dark:bg-gray-800", !this.rolePaneOpen)
    }
  }

  #updateContextToggleAffordance() {
    if (!this.hasContextPaneToggleTarget) return

    this.contextPaneToggleTarget.classList.toggle("bg-primary/10", this.contextPaneOpen)
    this.contextPaneToggleTarget.classList.toggle("text-primary", this.contextPaneOpen)
    this.contextPaneToggleTarget.classList.toggle("bg-gray-100", !this.contextPaneOpen)
    this.contextPaneToggleTarget.classList.toggle("dark:bg-gray-800", !this.contextPaneOpen)
  }
}

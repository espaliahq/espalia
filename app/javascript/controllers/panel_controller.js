// Reusable panel toggle controller with click-outside-to-close on mobile.
//
// Extracted from framework_explorer_controller.js to share between
// the framework explorer (role pane) and assessment view (scoring panel).
//
// <div data-controller="panel">
//   <button data-action="panel#toggle">Toggle</button>
//   <aside data-panel-target="panel" class="max-lg:hidden ...">...</aside>
// </div>

import { Controller } from "@hotwired/stimulus"
import { useClickOutside } from "stimulus-use"

export default class extends Controller {
  static targets = ["panel", "chevron"]
  static values = {
    mobileBreakpoint: { type: Number, default: 1024 },
    side: { type: String, default: "right" }
  }

  connect() {
    this.isMobile = window.innerWidth < this.mobileBreakpointValue
    this.panelOpen = !this.isMobile
  }

  toggle() {
    if (!this.hasPanelTarget) return

    this.isMobile = window.innerWidth < this.mobileBreakpointValue

    if (this.panelOpen) {
      this.close()
    } else {
      this.open()
    }

    this.#updateChevron()
  }

  open() {
    this.panelOpen = true

    if (this.isMobile) {
      const side = this.sideValue
      Object.assign(this.panelTarget.style, {
        display: "flex",
        flexDirection: "column",
        position: "fixed",
        top: "0",
        bottom: "0",
        [side]: "0",
        zIndex: "40",
        width: "20rem"
      })
      useClickOutside(this, { element: this.panelTarget })
    } else {
      this.panelTarget.removeAttribute("style")
    }
  }

  close() {
    this.panelOpen = false

    if (this.isMobile) {
      this.panelTarget.removeAttribute("style")
    } else {
      this.panelTarget.style.display = "none"
    }
  }

  clickOutside(event) {
    if (!this.panelOpen) return
    if (event.target.closest("[data-action*='panel#toggle']")) return

    this.close()
    this.#updateChevron()
  }

  // private

  #updateChevron() {
    if (this.hasChevronTarget) {
      this.chevronTarget.classList.toggle("rotate-180", this.panelOpen)
    }
  }
}

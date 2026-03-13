// Toggles the sidebar drawer on mobile viewports.
//
// Usage:
//   <div data-controller="sidebar">
//     <button data-action="sidebar#toggle">☰</button>
//     <aside data-sidebar-target="drawer" class="hidden md:flex ...">...</aside>
//   </div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["drawer"]

  toggle() {
    this.drawerTarget.classList.toggle("hidden")
  }
}

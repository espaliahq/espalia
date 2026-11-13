// Keeps a drawer that covers the whole screen to itself: below `lg`, where
// the Org Graph drawer takes the page, everything outside it turns `inert`,
// so the tab order and assistive technology reach only the drawer, and focus
// moves to its title. The toast stack stays live. From `lg` up the drawer
// sits beside the page, which stays usable.
//
// <aside data-controller="drawer-isolation">
//   <h2 data-drawer-isolation-target="title" tabindex="-1">…</h2>
// </aside>

import BaseController from "controllers/base_controller"

const COVERS_PAGE = "(max-width: 1023.98px)"

export default class extends BaseController {
  static targets = ["title"]

  connect() {
    super.connect()
    this.inerted = []
    this.media = window.matchMedia(COVERS_PAGE)
    this.boundApply = this.apply.bind(this)
    this.media.addEventListener("change", this.boundApply)
    this.apply()
    if (this.media.matches && this.hasTitleTarget) this.titleTarget.focus()
  }

  disconnect() {
    this.media.removeEventListener("change", this.boundApply)
    this.release()
    super.disconnect()
  }

  // private

  apply() {
    this.release()
    if (!this.media.matches) return

    for (let node = this.element; node.parentElement; node = node.parentElement) {
      for (const sibling of node.parentElement.children) {
        if (sibling === node || sibling.inert || this.keep(sibling)) continue
        sibling.inert = true
        this.inerted.push(sibling)
      }
    }
  }

  // Toasts announce the change just made, so they stay reachable.
  keep(element) {
    return ["SCRIPT", "STYLE"].includes(element.tagName) || element.hasAttribute("data-toast-stack")
  }

  release() {
    this.inerted.forEach((element) => { element.inert = false })
    this.inerted = []
  }
}

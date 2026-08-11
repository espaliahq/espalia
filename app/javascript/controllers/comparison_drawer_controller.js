// The calibration comparison drawer's chrome: measured page clearance,
// the ✕-collapse / expand-bar toggle, and drag-to-resize on the top
// handle (dragging within 20px of the viewport bottom collapses). The
// drawer is server-rendered and FIXED to the viewport bottom; this
// controller pads the host page by the drawer's real height — measured,
// so it tracks content, resize, and collapse — and applies it on connect
// so it survives Turbo Frame swaps (a server-rendered class on the
// wrapper outside the frame could not). Collapse and height persist via
// cookies, so a room keeps its arrangement across pane swaps.
//
// Example usage:
// <div data-controller="comparison-drawer">
//   <div data-comparison-drawer-target="handle"
//        data-action="pointerdown->comparison-drawer#resizeStart"></div>
//   <button data-comparison-drawer-target="collapse"
//           data-action="comparison-drawer#toggle">×</button>
//   <button data-comparison-drawer-target="expandBar" class="hidden"
//           data-action="comparison-drawer#toggle">expand</button>
//   <div data-comparison-drawer-target="body">…cards…</div>
// </div>

import BaseController from "controllers/base_controller"

const COLLAPSED_COOKIE = "calibration_drawer_collapsed"
const HEIGHT_COOKIE = "calibration_drawer_height"
const MIN_HEIGHT = 120
const CLOSE_ZONE = 20

export default class extends BaseController {
  static targets = ["body", "handle", "collapse", "expandBar"]

  connect() {
    super.connect()
    const height = parseInt(this.#cookie(HEIGHT_COOKIE), 10)
    if (height) this.bodyTarget.style.height = `${this.#clampHeight(height)}px`
    this.#apply(this.#cookie(COLLAPSED_COOKIE) === "1")
    this._onMove = this.#resizeMove.bind(this)
    this._onUp = this.#resizeEnd.bind(this)
  }

  disconnect() {
    // The drawer left with its frame (last card closed/unpinned) — release
    // the clearance so no dead scroll space remains.
    this.#host()?.style.removeProperty("padding-bottom")
    this.#unbindDrag()
    super.disconnect()
  }

  toggle() {
    const collapse = this.bodyTarget.style.display !== "none"
    this.#apply(collapse)
    this.#writeCookie(COLLAPSED_COOKIE, collapse ? "1" : "")
  }

  resizeStart(event) {
    event.preventDefault()
    window.addEventListener("pointermove", this._onMove)
    window.addEventListener("pointerup", this._onUp)
  }

  // private

  #resizeMove(event) {
    // Dragging the handle into the bottom edge closes the drawer — the
    // gesture already says "get this out of the way".
    if (event.clientY > window.innerHeight - CLOSE_ZONE) {
      this.#unbindDrag()
      this.#apply(true)
      this.#writeCookie(COLLAPSED_COOKIE, "1")
      return
    }
    const chrome = this.element.offsetHeight - this.bodyTarget.offsetHeight
    const height = this.#clampHeight(window.innerHeight - event.clientY - chrome)
    this.bodyTarget.style.height = `${height}px`
    this.#pad()
  }

  #resizeEnd() {
    this.#unbindDrag()
    this.#writeCookie(HEIGHT_COOKIE, `${this.bodyTarget.offsetHeight}`)
  }

  #unbindDrag() {
    window.removeEventListener("pointermove", this._onMove)
    window.removeEventListener("pointerup", this._onUp)
  }

  #clampHeight(height) {
    return Math.max(MIN_HEIGHT, Math.min(height, Math.round(window.innerHeight * 0.8)))
  }

  #apply(collapse) {
    this.bodyTarget.style.display = collapse ? "none" : ""
    this.handleTarget.style.display = collapse ? "none" : ""
    this.collapseTarget.style.display = collapse ? "none" : ""
    this.expandBarTarget.classList.toggle("hidden", !collapse)
    this.expandBarTarget.classList.toggle("inline-flex", collapse)
    this.collapseTarget.setAttribute("aria-expanded", collapse ? "false" : "true")
    this.expandBarTarget.setAttribute("aria-expanded", collapse ? "false" : "true")
    this.#pad()
  }

  // Clearance = the drawer's measured height (+ breathing room), so page-end
  // content can always scroll above the fixed shelf — exact whether the
  // drawer holds one collapsed bar or three tall cards.
  #pad() {
    const host = this.#host()
    if (host) host.style.paddingBottom = `${this.element.offsetHeight + 16}px`
  }

  #host() {
    return document.querySelector("[data-drawer-host]")
  }

  #cookie(name) {
    const entry = document.cookie.split("; ").find(pair => pair.startsWith(`${name}=`))
    return entry ? entry.slice(name.length + 1) : ""
  }

  #writeCookie(name, value) {
    document.cookie = `${name}=${value}; path=/; max-age=31536000; SameSite=Lax`
  }
}

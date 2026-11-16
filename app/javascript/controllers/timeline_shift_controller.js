// Drag a timeline bar's edge one step earlier or later to move the change it
// starts or ends with (https://github.com/espaliahq/espalia/issues/393). Each
// grip lists the steps it can reach. While a grip is held, those columns are
// lit and say "Move here"; letting go over one clicks the bar's "When…" item
// for that edge and step, so Turbo posts it as the menu would. Anywhere else,
// or Escape, saves nothing.
//
// The columns are found by the pointer's x against each step's header, so
// steps of any width behave alike. A pointer above or below the grid is over
// no column.
//
// Usage:
//   <div data-controller="timeline-shift">
//     <div data-timeline-step="1">… <p class="invisible" data-timeline-shift-hint="1">Move here</p></div>
//     <div data-timeline-shift-column="1"></div>
//     <div data-shifting?>
//       <a data-turbo-method="post" data-timeline-shift="start:2" href="/planning/…/change-moves?…">…</a>
//       <span data-timeline-shift-edge="start" data-timeline-shift-targets="[2]"
//             data-action="pointerdown->timeline-shift#start"></span>
//     </div>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  disconnect() {
    this.#finish()
    super.disconnect()
  }

  start(event) {
    if (event.button !== 0 || this.sent) return
    if (this.grip) this.#finish()

    event.preventDefault()
    this.grip = event.currentTarget
    this.reach = JSON.parse(this.grip.dataset.timelineShiftTargets).map(String)
    this.headers = [ ...this.element.querySelectorAll("[data-timeline-step]") ]
    this.over = null
    this.pointerId = event.pointerId
    this.grip.setPointerCapture(event.pointerId)
    this.bar = this.grip.parentElement
    this.bar.dataset.shifting = ""
    this.reach.forEach(step => {
      this.#column(step).dataset.lit = ""
      this.#hint(step).classList.remove("invisible")
    })

    this.listeners = {
      pointermove: e => this.#move(e),
      pointerup: e => this.#drop(e),
      pointercancel: () => this.#finish()
    }
    Object.entries(this.listeners).forEach(([type, fn]) => this.grip.addEventListener(type, fn))
    this.escape = e => { if (e.key === "Escape") this.#finish() }
    window.addEventListener("keydown", this.escape)
    // On document, since a removed grip loses its capture there rather than on itself.
    this.lost = e => { if (e.pointerId === this.pointerId) this.#finish() }
    document.addEventListener("lostpointercapture", this.lost)
  }

  // private

  #move(event) {
    const step = this.#stepAt(event.clientX, event.clientY)
    const over = this.reach.includes(step) ? step : null
    if (over === this.over) return

    if (this.over !== null) delete this.#column(this.over).dataset.over
    if (over !== null) this.#column(over).dataset.over = ""
    this.over = over
  }

  #drop(event) {
    this.#move(event)
    const edge = this.grip.dataset.timelineShiftEdge
    const item = this.over === null ? null : this.bar.querySelector(`[data-timeline-shift="${edge}:${this.over}"]`)
    this.#finish()
    if (!item) return

    // The page still shows the old step until Turbo's redirect lands, and a
    // second drop from it would move the change twice. A request that fails
    // leaves the page as it was, so it frees the grips again.
    this.sent = true
    const path = new URL(item.href).pathname
    const settled = e => {
      if (new URL(e.target.action).pathname !== path) return
      document.removeEventListener("turbo:submit-end", settled)
      if (!e.detail.success) this.sent = false
    }
    document.addEventListener("turbo:submit-end", settled)
    item.click()
  }

  #finish() {
    if (!this.grip) return

    Object.entries(this.listeners).forEach(([type, fn]) => this.grip.removeEventListener(type, fn))
    window.removeEventListener("keydown", this.escape)
    document.removeEventListener("lostpointercapture", this.lost)
    delete this.bar.dataset.shifting
    this.reach.forEach(step => {
      const column = this.#column(step)
      delete column.dataset.lit
      delete column.dataset.over
      this.#hint(step).classList.add("invisible")
    })
    this.grip = null
  }

  #stepAt(x, y) {
    const { top, bottom } = this.element.getBoundingClientRect()
    if (y < top || y >= bottom) return null

    const header = this.headers.find(cell => {
      const { left, right } = cell.getBoundingClientRect()
      return x >= left && x < right
    })
    return header ? header.dataset.timelineStep : null
  }

  #column(step) { return this.element.querySelector(`[data-timeline-shift-column="${step}"]`) }

  #hint(step) { return this.element.querySelector(`[data-timeline-shift-hint="${step}"]`) }
}

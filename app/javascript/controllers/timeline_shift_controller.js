// Drag a timeline bar's edge one step earlier or later to move the change it
// starts or ends with (#393). Each grip lists the steps it can reach and, for
// each, the URL its bar's "When…" item posts. While a grip is held, those
// columns are lit and say "Move here"; letting go over one posts its URL, as
// the menu item would. Anywhere else, or Escape, saves nothing.
//
// The columns are found by the pointer's x against each step's header, so
// steps of any width behave alike.
//
// Usage:
//   <div data-controller="timeline-shift">
//     <div data-timeline-step="1">… <p data-timeline-shift-hint="1" hidden>Move here</p></div>
//     <div data-timeline-shift-column="1"></div>
//     <div data-shifting?>
//       <span data-timeline-shift-edge="start" data-timeline-shift-targets='{"2":"/planning/…/change-moves?…"}'
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
    if (event.button !== 0 || this.grip) return

    event.preventDefault()
    this.grip = event.currentTarget
    this.reach = JSON.parse(this.grip.dataset.timelineShiftTargets)
    this.over = null
    this.grip.setPointerCapture(event.pointerId)
    this.grip.parentElement.dataset.shifting = ""
    Object.keys(this.reach).forEach(step => {
      this.#column(step).dataset.lit = ""
      this.#hint(step).hidden = false
    })

    this.listeners = {
      pointermove: e => this.#move(e),
      pointerup: e => this.#drop(e),
      pointercancel: () => this.#finish(),
      lostpointercapture: () => this.#finish()
    }
    Object.entries(this.listeners).forEach(([type, fn]) => this.grip.addEventListener(type, fn))
    this.escape = e => { if (e.key === "Escape") this.#finish() }
    window.addEventListener("keydown", this.escape)
  }

  // private

  #move(event) {
    const step = this.#stepAt(event.clientX)
    const over = step in this.reach ? step : null
    if (over === this.over) return

    if (this.over !== null) delete this.#column(this.over).dataset.over
    if (over !== null) this.#column(over).dataset.over = ""
    this.over = over
  }

  #drop(event) {
    this.#move(event)
    const url = this.over === null ? null : this.reach[this.over]
    this.#finish()
    if (url) this.#post(url)
  }

  #finish() {
    if (!this.grip) return

    Object.entries(this.listeners).forEach(([type, fn]) => this.grip.removeEventListener(type, fn))
    window.removeEventListener("keydown", this.escape)
    delete this.grip.parentElement.dataset.shifting
    Object.keys(this.reach).forEach(step => {
      const column = this.#column(step)
      delete column.dataset.lit
      delete column.dataset.over
      this.#hint(step).hidden = true
    })
    this.grip = null
  }

  // Posted the way Turbo posts a `data-turbo-method="post"` link, so the
  // redirect and its notice or alert land as the "When…" item's do.
  #post(url) {
    const form = document.createElement("form")
    form.method = "post"
    form.action = url
    form.hidden = true
    document.body.appendChild(form)
    form.requestSubmit()
  }

  #stepAt(x) {
    const header = [ ...this.element.querySelectorAll("[data-timeline-step]") ].find(cell => {
      const { left, right } = cell.getBoundingClientRect()
      return x >= left && x < right
    })
    return header ? header.dataset.timelineStep : null
  }

  #column(step) { return this.element.querySelector(`[data-timeline-shift-column="${step}"]`) }

  #hint(step) { return this.element.querySelector(`[data-timeline-shift-hint="${step}"]`) }
}

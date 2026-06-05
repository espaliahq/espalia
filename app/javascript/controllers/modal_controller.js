// Generic modal controller backing Components::Kit::Modal.
//
// Owns visibility only: open/close, body-scroll-lock, click-outside, and
// (via the host element's keydown.esc action) Esc-to-close. On open it
// dispatches a window `modal:open` CustomEvent carrying the triggering
// element's dataset, so a sibling feature controller can prefill form fields
// without this controller knowing their shape.
//
// Standalone usage (co-located trigger):
//   <div data-controller="modal" data-action="keydown.esc@window->modal#close">
//     <button data-action="modal#open">Open</button>
//     <div data-modal-target="overlay">…<div data-modal-target="panel">…</div></div>
//   </div>
//
// Embedded usage (many remote triggers share one modal): place
// data-controller="modal" on a common ancestor; remote triggers fire
// data-action="click->modal#open".

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["overlay", "panel"]

  connect() {
    super.connect()
    this.boundClickOutside = this.clickOutside.bind(this)
  }

  disconnect() {
    document.removeEventListener("click", this.boundClickOutside, true)
    document.body.style.overflow = ""
    super.disconnect()
  }

  open(event) {
    const trigger = event.currentTarget
    window.dispatchEvent(new CustomEvent("modal:open", {
      detail: { id: this.hasOverlayTarget ? this.overlayTarget.id : null, dataset: trigger?.dataset || {} }
    }))
    this.show()
  }

  close() {
    this.hide()
  }

  // turbo:submit-end fires after a Turbo-handled submit settles; close only on
  // success so validation errors keep the form visible to fix and retry.
  submitted(event) {
    if (event.detail?.success) this.hide()
  }

  // private

  show() {
    this.overlayTarget.classList.remove("hidden")
    this.overlayTarget.classList.add("flex")
    document.body.style.overflow = "hidden"
    // Defer so the click that opened us (originating outside the panel) does
    // not immediately close it on the next listener pass.
    queueMicrotask(() => {
      document.addEventListener("click", this.boundClickOutside, true)
    })
    const focusable = this.overlayTarget.querySelector("textarea, input:not([type='hidden']), select")
    focusable && focusable.focus()
  }

  hide() {
    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.classList.remove("flex")
    document.body.style.overflow = ""
    document.removeEventListener("click", this.boundClickOutside, true)
  }

  clickOutside(event) {
    if (this.panelTarget.contains(event.target)) return
    // Ignore any open-trigger — its own click is what opened us.
    if (event.target.closest("[data-action*='modal#open']")) return
    this.hide()
  }
}

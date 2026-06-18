// Generic modal controller backing Components::Kit::Modal.
//
// Owns visibility only: open/close, body-scroll-lock, and (via the host
// element's keydown.esc action) Esc-to-close. On open it dispatches a window
// `modal:open` CustomEvent carrying the triggering element's dataset, so a
// sibling feature controller can prefill form fields without this controller
// knowing their shape.
//
// Click-outside dismissal is OPT-IN via the `dismissOnOutsideClick` value
// (default false). Transactional modals (anything holding unsaved user input)
// must leave it off so a stray background click can't discard the form — they
// close only through the × button, a Cancel action, Esc, or a successful
// submit. Set it true only for purely informational modals where an outside
// click is a safe, expected dismissal.
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
//
// Multiple modals under one controller: when more than one overlay sits under
// the same `modal` controller, each trigger must name which to open via
// `data-modal-target-id="<overlay id>"`. With a single overlay and no such
// attribute, it falls back to that overlay (backward-compatible).

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["overlay", "panel"]
  static values = { dismissOnOutsideClick: Boolean }

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
    this.activeOverlay = this.#resolveOverlay(trigger)
    if (!this.activeOverlay) return
    window.dispatchEvent(new CustomEvent("modal:open", {
      detail: { id: this.activeOverlay.id, dataset: trigger?.dataset || {} }
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

  // Pick the overlay a trigger targets: by `data-modal-target-id` when set
  // (required once >1 overlay shares this controller), else the lone overlay.
  #resolveOverlay(trigger) {
    const id = trigger?.dataset?.modalTargetId
    if (id) return this.overlayTargets.find((o) => o.id === id) || null
    return this.hasOverlayTarget ? this.overlayTarget : null
  }

  #activePanel() {
    return this.activeOverlay?.querySelector("[data-modal-target='panel']")
  }

  show() {
    const overlay = this.activeOverlay
    if (!overlay) return
    overlay.classList.remove("hidden")
    overlay.classList.add("flex")
    document.body.style.overflow = "hidden"
    // Click-outside is opt-in (informational modals only). Defer registration
    // so the click that opened us (originating outside the panel) does not
    // immediately close it on the next listener pass.
    if (this.dismissOnOutsideClickValue) {
      queueMicrotask(() => {
        document.addEventListener("click", this.boundClickOutside, true)
      })
    }
    const focusable = overlay.querySelector("textarea, input:not([type='hidden']), select")
    focusable && focusable.focus()
  }

  hide() {
    const overlay = this.activeOverlay
    if (!overlay) return
    overlay.classList.add("hidden")
    overlay.classList.remove("flex")
    document.body.style.overflow = ""
    document.removeEventListener("click", this.boundClickOutside, true)
  }

  clickOutside(event) {
    const panel = this.#activePanel()
    if (panel && panel.contains(event.target)) return
    // Ignore any open-trigger — its own click is what opened us.
    if (event.target.closest("[data-action*='modal#open']")) return
    this.hide()
  }
}

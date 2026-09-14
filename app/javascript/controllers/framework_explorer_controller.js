// Framework Explorer shell controller.
//
// Manages the three-pane layout and the two pane toggles.
// On mobile (< lg): BOTH side panes are fixed overlays, closed by default, and
// dismissed by an outside tap, Esc, or (the context pane) its own ×. The matrix
// gets the full width in between.
// On desktop (lg+): the panes are inline columns whose toggles show/hide them.
//
// It also publishes `--explorer-offset` — the measured distance from the top of
// the document to the explorer layout — so the layout can be exactly the
// leftover viewport (`h-[calc(100dvh - var(--explorer-offset))]`) at any width.
// The old hard-coded `12rem` only ever described the desktop header; once the
// header wraps on a phone it is twice that and the grid hung below the fold.
//
// <div data-controller="framework-explorer"
//      data-action="keydown.esc@window->framework-explorer#closeOverlayPanes
//                   resize@window->framework-explorer#viewportChanged">
//   <div data-framework-explorer-target="chrome">… header …</div>
//   <button data-action="framework-explorer#toggleRolePane"
//           data-framework-explorer-target="rolePaneToggle">
//     <svg data-framework-explorer-target="toggleChevron">...</svg>
//     4 Roles
//   </button>
//   <div data-framework-explorer-target="layout">
//     <aside data-framework-explorer-target="rolePane" class="max-lg:hidden ...">…</aside>
//     <aside data-framework-explorer-target="contextPane" class="max-lg:hidden ...">…</aside>
//   </div>
// </div>

import BaseController from "controllers/base_controller"
import { useClickOutside } from "stimulus-use"

// The `lg` breakpoint, in one place — the panes' `max-lg:hidden` and this
// controller's overlay behaviour have to agree or a pane gets inline styles
// CSS is about to override (or vice versa).
const DESKTOP_MIN_WIDTH = 1024

export default class extends BaseController {
  static targets = ["rolePane", "contextPane", "rolePaneToggle", "toggleChevron",
                     "roleCount", "roleLabel", "contextPaneToggle", "layout", "chrome"]

  connect() {
    super.connect()
    this.isMobile = window.innerWidth < DESKTOP_MIN_WIDTH
    // On desktop the panes start visible; on mobile both start hidden (their
    // `max-lg:hidden` says so) so the matrix owns the whole viewport.
    this.rolePaneOpen = !this.isMobile
    // Read the context pane's initial open/closed state from the DOM. Edit
    // mode server-renders the pane with `flex` (open); view mode omits it
    // entirely. Initialising from the rendered classes keeps the toggle
    // affordance in sync with what the user actually sees.
    this.contextPaneOpen = this.hasContextPaneTarget && !this.isMobile &&
      !this.contextPaneTarget.classList.contains("hidden")
    this.#updateToggleAffordance()
    this.#updateContextToggleAffordance()
    this.#observeChrome()
    this.publishLayoutOffset()
  }

  disconnect() {
    this.chromeObserver?.disconnect()
    this.chromeObserver = null
    super.disconnect()
  }

  toggleRolePane() {
    if (!this.hasRolePaneTarget) return

    this.isMobile = window.innerWidth < DESKTOP_MIN_WIDTH

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

    this.isMobile = window.innerWidth < DESKTOP_MIN_WIDTH
    this.contextPaneOpen = !this.contextPaneOpen

    if (this.contextPaneOpen) {
      this.#openContextPane()
    } else {
      this.#closeContextPane()
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

  // Called by useClickOutside for either overlay pane. Both registrations call
  // this one method (stimulus-use has no per-element callback name), so it
  // re-checks containment itself rather than trusting which one fired.
  clickOutside(event) {
    this.#closeIfOutside(event, "role")
    this.#closeIfOutside(event, "context")
  }

  // Esc closes whichever pane is covering the grid. A modal or a kebab menu
  // owns Esc while it is open — closing the pane underneath one would pull the
  // rug out from a dialog the user is still in.
  closeOverlayPanes() {
    if (!this.isMobile || this.#somethingElseIsOpen()) return

    if (this.rolePaneOpen && this.hasRolePaneTarget) {
      this.#closeRolePane()
      this.#updateToggleAffordance()
      if (this.hasRolePaneToggleTarget) this.rolePaneToggleTarget.focus()
    } else if (this.contextPaneOpen && this.hasContextPaneTarget) {
      // #closeContextPane returns focus to the toggle itself when it was
      // inside the pane, which it is after an Esc.
      this.#closeContextPane()
      this.#updateContextToggleAffordance()
    }
  }

  // Crossing the `lg` boundary changes what "open" means for both panes —
  // an overlay's inline styles have to come off on the way up, and the
  // desktop-open default has to become closed on the way down.
  viewportChanged() {
    const wasMobile = this.isMobile
    this.isMobile = window.innerWidth < DESKTOP_MIN_WIDTH
    this.publishLayoutOffset()
    if (wasMobile === this.isMobile) return

    if (this.hasRolePaneTarget) {
      this.rolePaneTarget.removeAttribute("style")
      this.rolePaneOpen = !this.isMobile
      if (this.isMobile) {
        this.#rescueFocusFrom(this.rolePaneTarget, this.hasRolePaneToggleTarget ? this.rolePaneToggleTarget : null)
      }
      this.#updateToggleAffordance()
    }
    if (this.hasContextPaneTarget) {
      this.contextPaneTarget.removeAttribute("style")
      this.contextPaneTarget.classList.remove("hidden")
      this.contextPaneTarget.classList.add("flex")
      this.contextPaneOpen = !this.isMobile
      if (this.isMobile) {
        this.#rescueFocusFrom(this.contextPaneTarget,
          this.hasContextPaneToggleTarget ? this.contextPaneToggleTarget : null)
      }
      this.#updateContextToggleAffordance()
    }
  }

  // Crossing below `lg` hides a pane through `max-lg:hidden` without any
  // close call — so keyboard focus that was inside it would be stranded on a
  // hidden element. Hand it to the pane's toggle, the same place Esc and an
  // outside tap leave it.
  #rescueFocusFrom(pane, toggle) {
    if (!pane.contains(document.activeElement)) return

    if (toggle) toggle.focus()
    else document.activeElement.blur()
  }

  // Measures how much viewport the page chrome above the explorer consumes and
  // publishes it as `--explorer-offset`. Only the chrome's height feeds this,
  // so the layout resizing itself can never feed back into the measurement.
  publishLayoutOffset() {
    if (!this.hasLayoutTarget) return

    const docTop = document.documentElement.getBoundingClientRect().top
    const top = Math.ceil(this.layoutTarget.getBoundingClientRect().top - docTop)
    if (top === this.publishedOffset) return

    this.publishedOffset = top
    this.element.style.setProperty("--explorer-offset", `${top}px`)
  }

  // private

  // Is a modal or a menu currently open on top of the panes? Both own their
  // own dismissal, so a pane must not act on an Esc or an outside click while
  // one is up. `:not(.hidden)` matters for the menu: a `Kit::Dropdown` renders
  // its menu closed-but-present, so a bare `[role='menu']` matches on every
  // edit-mode page and disarms the guard entirely (Hard-Won Lesson 37).
  #somethingElseIsOpen() {
    return Boolean(
      document.querySelector("[data-modal-target='overlay']:not(.hidden)") ||
      document.querySelector("[role='menu']:not(.hidden)")
    )
  }

  #observeChrome() {
    if (!this.hasChromeTarget || typeof ResizeObserver === "undefined") return

    this.chromeObserver = new ResizeObserver(() => this.publishLayoutOffset())
    this.chromeObserver.observe(this.chromeTarget)
  }

  #closeIfOutside(event, which) {
    const isRole = which === "role"
    const present = isRole ? this.hasRolePaneTarget : this.hasContextPaneTarget
    const open = isRole ? this.rolePaneOpen : this.contextPaneOpen
    if (!present || !open || !this.isMobile) return

    const pane = isRole ? this.rolePaneTarget : this.contextPaneTarget
    const action = isRole ? "toggleRolePane" : "toggleContextPane"

    if (pane.contains(event.target)) return
    if (event.target.closest(`[data-action*='${action}']`)) return
    // Same hand-off rule as Esc. Every modal lives on the explorer ROOT, not
    // inside the pane, so without this the first tap inside a Reject / Resolve
    // / Add-level dialog reads as "outside the pane" and quietly closes the
    // feed the reviewer opened it from.
    if (this.#somethingElseIsOpen()) return

    // The dismissal consumes the tap. `useClickOutside` listens on `window` in
    // the CAPTURE phase and does not stop the event, so without this the tap
    // that closes the overlay carries on to whatever it landed on — the strip
    // of grid left visible beside the pane is exactly the matrix, so dismissing
    // the feed also expanded a capability row under it.
    event.stopPropagation()
    event.preventDefault()

    if (isRole) {
      this.#closeRolePane()
      this.#updateToggleAffordance()
    } else {
      this.#closeContextPane()
      this.#updateContextToggleAffordance()
    }
  }

  // One overlay at a time. Both are `z-index: 30` fixed panels, so a second
  // one opened over the first just buries it: invisible, still "open", and
  // still the pane Esc closes first.
  #closeOtherOverlay(which) {
    if (!this.isMobile) return

    if (which === "role" && this.hasContextPaneTarget && this.contextPaneOpen) {
      this.#closeContextPane()
      this.#updateContextToggleAffordance()
    } else if (which === "context" && this.hasRolePaneTarget && this.rolePaneOpen) {
      this.#closeRolePane()
      this.#updateToggleAffordance()
    }
  }

  #openRolePane() {
    this.rolePaneOpen = true

    if (this.isMobile) {
      this.#closeOtherOverlay("role")
      Object.assign(this.rolePaneTarget.style, this.#overlayStyle("18rem", { left: "0" }))
      this.#watchOutsideClicks(this.rolePaneTarget)
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

  #openContextPane() {
    if (this.isMobile) {
      this.#closeOtherOverlay("context")
      // Inline styles, not classes: the pane carries `max-lg:hidden`, and a
      // variant beats any plain `display` utility we could add at this width
      // (Hard-Won Lesson 3).
      Object.assign(this.contextPaneTarget.style, this.#overlayStyle("20rem", { right: "0" }))
      this.#watchOutsideClicks(this.contextPaneTarget)
      // The overlay covers the grid, so keyboard focus has to follow it in —
      // otherwise Tab walks straight into the matrix controls underneath with
      // nothing to say the panel was left. Focus returns to the toggle on
      // every close path below. Containment is deliberately NOT claimed: the
      // pane stays a landmark, not a dialog.
      this.contextPaneTarget.tabIndex = -1
      this.contextPaneTarget.focus({ preventScroll: true })
    } else {
      this.contextPaneTarget.classList.remove("hidden")
      this.contextPaneTarget.classList.add("flex")
    }
  }

  #closeContextPane() {
    this.contextPaneOpen = false
    if (this.isMobile) {
      const held = this.contextPaneTarget.contains(document.activeElement)
      this.contextPaneTarget.removeAttribute("style")
      if (held && this.hasContextPaneToggleTarget) this.contextPaneToggleTarget.focus()
    } else {
      this.contextPaneTarget.classList.add("hidden")
      this.contextPaneTarget.classList.remove("flex")
    }
  }

  // Shared overlay geometry for both panes — each keeps its desktop width,
  // floored so a strip of the matrix always shows at 375 px. That strip is
  // both the cue that the pane is covering something and the target for the
  // outside tap that dismisses it.
  #overlayStyle(width, edge) {
    return {
      display: "flex",
      position: "fixed",
      top: "0",
      bottom: "0",
      zIndex: "30",
      width: `min(${width}, calc(100vw - 3rem))`,
      boxShadow: "0 0 24px rgba(15, 23, 42, 0.25)",
      ...edge
    }
  }

  // `useClickOutside` registers a fresh window listener every call, so a pane
  // opened five times used to be checked five times per click. Register once
  // per element and leave it — the handler re-checks `open` anyway.
  #watchOutsideClicks(element) {
    this.watchedPanes ||= new WeakSet()
    if (this.watchedPanes.has(element)) return

    this.watchedPanes.add(element)
    useClickOutside(this, { element })
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
      this.rolePaneToggleTarget.setAttribute("aria-expanded", String(this.rolePaneOpen))
    }
  }

  #updateContextToggleAffordance() {
    if (!this.hasContextPaneToggleTarget) return

    this.contextPaneToggleTarget.classList.toggle("bg-primary/10", this.contextPaneOpen)
    this.contextPaneToggleTarget.classList.toggle("text-primary", this.contextPaneOpen)
    this.contextPaneToggleTarget.classList.toggle("bg-gray-100", !this.contextPaneOpen)
    this.contextPaneToggleTarget.classList.toggle("dark:bg-gray-800", !this.contextPaneOpen)
    this.contextPaneToggleTarget.setAttribute("aria-expanded", String(this.contextPaneOpen))
  }
}

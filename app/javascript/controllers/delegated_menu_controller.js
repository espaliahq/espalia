// One menu for many kebabs. A page with a ⋮ on every row mounts this once on
// a container and gives each row a bare trigger, rendered by
// `Components::Kit::DelegatedMenu.trigger`. The menu is built when a trigger
// opens it and torn down when it closes, so a row pays for its trigger alone.
//
// The items come from a `<template>` of that kind, rendered once on the page.
// `{name}` in an item's attribute is filled from the trigger's
// `data-menu-<name>`, so the same template serves every row. A surface whose
// items depend on more than the trigger's data (the framework explorer)
// extends this class and overrides `items(trigger)`.
//
// Usage:
//   <div data-controller="delegated-menu"
//        data-action="keydown.esc@window->delegated-menu#escape keydown->delegated-menu#keydown
//                     click@window->delegated-menu#clickOutside">
//     <template data-delegated-menu-kind="position">
//       <button type="button" role="menuitem" data-position-action="{path}">Edit…</button>
//     </template>
//     <button type="button" aria-haspopup="menu" aria-expanded="false" aria-label="Actions for Designer"
//             data-action="delegated-menu#toggle" data-menu="position" data-menu-path="/planning/…">⋮</button>
//   </div>
//
// The menu is inserted after its trigger, so an item reaches the controllers
// around the row (`modal#open`, `closest(…)` lookups), and `position: fixed`
// keeps it out of any scroll clipping.

import BaseController from "controllers/base_controller"

const MENU_CLASSES =
  "fixed z-50 max-h-[70vh] w-56 overflow-y-auto rounded-md shadow-overlay border border-default bg-overlay py-1"

const VIEWPORT_MARGIN = 8

// `position: fixed` escapes clipping but not paint order: the menu still
// composites inside the nearest stacking context, where a sticky sibling of
// the same rank paints over it. This lifts that ancestor while the menu is
// open, above body cells (z-2) and category headers (z-5) and below sticky
// column headers (z-10).
const LIFTED_Z = 9

let idSeed = 0

export default class extends BaseController {
  static menuClasses = MENU_CLASSES

  connect() {
    super.connect()
    this.openTrigger = null
    this.menu = null
    this.lifted = null
    this._onScroll = this.#onScroll.bind(this)
    // An item that opens a modal would otherwise leave the menu (z-50) over
    // the overlay (z-40) of the dialog it launched.
    this._onModalOpen = () => this.close()
    window.addEventListener("modal:open", this._onModalOpen)
  }

  disconnect() {
    this.#teardownMenu()
    window.removeEventListener("modal:open", this._onModalOpen)
    super.disconnect()
  }

  toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    const trigger = event.currentTarget
    const reopening = trigger === this.openTrigger
    this.close()
    if (reopening) return

    // detail === 0 is a keyboard click (Enter or Space), which moves focus
    // into the menu, as the APG menu button does.
    this.#open(trigger, { focusFirst: event.detail === 0 })
  }

  close() {
    const trigger = this.openTrigger
    this.#teardownMenu()
    if (trigger) trigger.setAttribute("aria-expanded", "false")
  }

  escape(event) {
    if (!this.openTrigger) return

    event.stopPropagation()
    const trigger = this.openTrigger
    this.close()
    trigger.focus()
  }

  clickOutside(event) {
    if (!this.menu) return
    if (this.menu.contains(event.target) || this.openTrigger?.contains(event.target)) return

    this.close()
  }

  // ArrowUp, ArrowDown, Home and End move between items; Tab and Escape close.
  keydown(event) {
    if (!this.menu) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.escape(event)
      return
    }
    if (event.key === "Tab") {
      // Focus goes back to the trigger first, so the browser's Tab moves on
      // from the kebab rather than from an item that is gone.
      this.close()
      return
    }
    const items = this.focusableItems()
    const index = items.indexOf(document.activeElement)
    let next = null
    if (event.key === "ArrowDown") next = items[index + 1] || items[0]
    else if (event.key === "ArrowUp") next = index <= 0 ? items[items.length - 1] : items[index - 1]
    else if (event.key === "Home") next = items[0]
    else if (event.key === "End") next = items[items.length - 1]
    if (!next) return

    event.preventDefault()
    next.focus()
  }

  // The menu's children for a trigger. Subclasses override this.
  items(trigger) {
    const template = this.element.querySelector(
      `template[data-delegated-menu-kind="${CSS.escape(trigger.dataset.menu || "")}"]`
    )
    if (!template) return []

    return Array.from(template.content.cloneNode(true).children).map((node) => fill(node, trigger))
  }

  // Called once the menu is in the page, before it is positioned.
  opened(_menu, _trigger) {}

  // Whether a click on this element inside the menu should leave it open.
  keepsOpen(_target) {
    return false
  }

  focusableItems() {
    if (!this.menu) return []

    return Array.from(this.menu.querySelectorAll("[role='menuitem']")).filter((el) => !el.disabled)
  }

  // private

  #open(trigger, { focusFirst }) {
    const items = this.items(trigger)
    if (!items.length) return

    const menu = document.createElement("div")
    menu.className = this.constructor.menuClasses
    menu.setAttribute("role", "menu")
    menu.setAttribute("aria-orientation", "vertical")
    const label = trigger.getAttribute("aria-label")
    if (label) menu.setAttribute("aria-label", label)
    menu.dataset.delegatedMenu = trigger.dataset.menu || ""
    // The item that opens a dialog goes with the menu, so the dialog hands
    // focus back to the trigger instead (`modal_controller` reads this).
    const returnId = this.#ensureId(trigger)
    items.forEach((node) => {
      if (node.matches?.("[role='menuitem']")) node.dataset.modalFocusReturn = returnId
      node.querySelectorAll?.("[role='menuitem']").forEach((el) => { el.dataset.modalFocusReturn = returnId })
      menu.appendChild(node)
    })

    this.#liftStackingContext(trigger)
    trigger.insertAdjacentElement("afterend", menu)
    // Capture phase, because an item's own action may stop propagation, and
    // deferred a task so that action runs before the menu goes.
    menu.addEventListener("click", (event) => {
      if (this.keepsOpen(event.target)) return

      setTimeout(() => this.close(), 0)
    }, true)

    this.menu = menu
    this.openTrigger = trigger
    trigger.setAttribute("aria-expanded", "true")
    this.opened(menu, trigger)

    this.#position()
    window.addEventListener("scroll", this._onScroll, true)
    window.addEventListener("resize", this._onScroll)
    if (focusFirst) this.focusableItems()[0]?.focus()
  }

  // Focus that is still inside the menu goes back to the trigger. An item
  // that moved it on purpose (a dialog, an editor) keeps it there.
  #returnFocus() {
    if (!this.menu?.contains(document.activeElement)) return

    this.openTrigger?.focus()
  }

  #ensureId(element) {
    if (!element.id) element.id = `${this.identifier}-trigger-${(idSeed += 1)}`

    return element.id
  }

  #teardownMenu() {
    this.#returnFocus()
    this.#restoreStackingContext()
    this.menu?.remove()
    this.menu = null
    this.openTrigger = null
    window.removeEventListener("scroll", this._onScroll, true)
    window.removeEventListener("resize", this._onScroll)
  }

  #liftStackingContext(trigger) {
    let node = trigger.parentElement
    while (node && node !== document.body) {
      const style = window.getComputedStyle(node)
      if (style.position !== "static" && style.zIndex !== "auto") {
        if (Number(style.zIndex) < LIFTED_Z) {
          this.lifted = { node, zIndex: node.style.zIndex }
          node.style.zIndex = String(LIFTED_Z)
        }
        return
      }
      node = node.parentElement
    }
  }

  #restoreStackingContext() {
    if (!this.lifted) return

    this.lifted.node.style.zIndex = this.lifted.zIndex
    this.lifted = null
  }

  // A fixed menu follows its trigger on scroll rather than closing.
  #onScroll() {
    // A Turbo Stream can replace the row the menu was built into.
    if (!this.menu?.isConnected || !this.openTrigger?.isConnected) {
      this.close()
      return
    }
    this.#position()
  }

  // Under the trigger, clamped into the viewport, and above it when there is
  // more room there.
  #position() {
    const menu = this.menu
    menu.style.maxHeight = ""
    const rect = this.openTrigger.getBoundingClientRect()
    const left = Math.max(
      VIEWPORT_MARGIN,
      Math.min(rect.left, window.innerWidth - menu.offsetWidth - VIEWPORT_MARGIN)
    )
    menu.style.left = `${left}px`
    menu.style.top = `${rect.bottom + 4}px`

    const height = menu.offsetHeight
    if (rect.bottom + 4 + height <= window.innerHeight - VIEWPORT_MARGIN) return

    const roomAbove = rect.top - VIEWPORT_MARGIN
    const roomBelow = window.innerHeight - rect.bottom - VIEWPORT_MARGIN
    if (roomAbove > roomBelow) {
      menu.style.top = `${Math.max(VIEWPORT_MARGIN, rect.top - height - 4)}px`
      menu.style.maxHeight = `${roomAbove}px`
    } else {
      menu.style.maxHeight = `${roomBelow}px`
    }
  }
}

// Fills `{name}` in every attribute of the node and its descendants from the
// trigger's `data-menu-<name>`. A missing value fills as "".
function fill(node, trigger) {
  [node, ...node.querySelectorAll("*")].forEach((element) => {
    Array.from(element.attributes).forEach((attribute) => {
      if (!attribute.value.includes("{")) return

      attribute.value = attribute.value.replace(/\{([a-z0-9-]+)\}/g, (_, name) =>
        trigger.getAttribute(`data-menu-${name}`) ?? ""
      )
    })
  })
  return node
}

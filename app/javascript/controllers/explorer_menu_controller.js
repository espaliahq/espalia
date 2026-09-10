// ONE kebab-menu controller for the whole Framework Explorer grid.
//
// Every ⋮ in the matrix used to be a full `Kit::Dropdown`: a wrapper div with
// its own `dropdown` mount (a window click-capture listener, a `modal:open`
// listener and a useTransition each), a hidden `role="menu"` panel, and every
// item pre-rendered with its ~200-byte class string — for a menu the user opens
// maybe once a session. Now the grid ships a bare trigger button carrying only
// the entity's ids, and this controller — mounted ONCE on the explorer root —
// builds the menu on open. Event delegation via Stimulus actions means triggers
// inserted late (the on-demand expanded row, a frame re-render) work with no
// extra wiring.
//
// A menu is a pure function of the trigger's dataset plus the coordinates
// already on the grid (`tr[data-capability-id]`, `tr[data-capability-name]`,
// `tr[data-category-id]`), so the server emits ids, never markup or labels.
// Trigger contract:
//
//   data-menu            capability | expectation | illustration | category |
//                        expectation-create | illustration-create
//   data-menu-*          the ids/flags that menu kind needs (see BUILDERS)
//
// Built items keep the `data-*` the real behaviour needs, so they still drive
// the SAME controllers they always did — `modal#open`, `field-editor#open`,
// `reorder-move#move`, `reorder-list#moveUp`, `suggestion-action#approve`.
// Those mount on the one open menu instead of on hundreds of closed ones.
//
// Resolved-suggestion memory: this controller outlives every menu, so it
// remembers which suggestions have resolved (from the window
// `suggestion:resolved` event) and renders their approve/reject items terminal
// when a menu is built later — the guarantee the per-kebab `suggestion-action`
// mount used to give a menu that was already in the DOM (Hard-Won Lesson 23).

import BaseController from "controllers/base_controller"

const MENU_CLASSES =
  "explorer-menu fixed z-50 max-h-[70vh] w-56 overflow-y-auto rounded-md shadow-lg " +
  "bg-white dark:bg-gray-800 ring-1 ring-black/5 dark:ring-white/10 py-1"

const VIEWPORT_MARGIN = 8

// Only used to mint an id for a trigger that has none, so a menu item can name
// it as the dialog's focus-return target.
let idSeed = 0

// `position: fixed` escapes overflow clipping but NOT paint order: a fixed
// element still composites inside the nearest ancestor that creates a stacking
// context. The matrix's sticky capability column is `z-[2]`, so a menu opened
// in one row was painted over by the equally-ranked sticky cell of the row
// BELOW it (reported from #380's visual pass — the row menu's last two items
// were covered). Lifting that ancestor while the menu is open fixes it without
// portalling the menu away from the entity its items resolve against.
//
// The value sits above the grid's body cells (z-2) and category headers (z-5)
// and below the sticky column headers (z-10) and corner (z-20), so an open menu
// never paints over the chrome that has to stay legible.
const LIFTED_Z = 9

// Reject-modal copy per suggestion kind: [what the verb acts on, what the modal
// calls the entity].
const SUGGESTION_LABELS = {
  capabilityName: ["name change", "capability name"],
  capabilityDescription: ["description change", "capability description"],
  expectation: ["expectation change", "expectation"],
  illustration: ["illustration change", "illustration"],
  "expectation-create": ["new expectation", "new expectation"],
  "illustration-create": ["new illustration", "new illustration"]
}

export default class extends BaseController {
  static values = {
    // { approve: "/frameworks/F/suggestions/:id/approve?inline=1", … } — path
    // templates so no Rails route is hand-written in JS.
    paths: { type: Object, default: {} }
  }

  connect() {
    super.connect()
    this.openTrigger = null
    this.menu = null
    this.lifted = null
    this.resolved = new Map()
    this._onScroll = this.#onScroll.bind(this)
    // A menu item that opens a modal leaves the menu on screen behind it — and
    // the menu (z-50) outranks the overlay (z-40), so it would render over the
    // dialog it just launched. Clicking the item isn't an "outside" click.
    this._onModalOpen = () => this.close()
    window.addEventListener("modal:open", this._onModalOpen)
  }

  disconnect() {
    this.#teardownMenu()
    window.removeEventListener("modal:open", this._onModalOpen)
    super.disconnect()
  }

  // ── Opening / closing ──

  toggle(event) {
    event.preventDefault()
    // Never let opening the menu also toggle the row / focus the cell beneath.
    event.stopPropagation()

    const trigger = event.currentTarget
    const reopening = trigger === this.openTrigger
    this.close()
    if (reopening) return

    // detail === 0 means the click came from the keyboard (Enter/Space), where
    // the APG menu-button pattern moves focus into the menu.
    this.#open(trigger, { focusFirst: event.detail === 0 })
  }

  close() {
    const trigger = this.openTrigger
    this.#teardownMenu()
    if (trigger) trigger.setAttribute("aria-expanded", "false")
  }

  // Esc closes and hands focus back to the trigger — the APG menu-button
  // contract.
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

  // Roving focus within the open menu (ArrowUp/Down/Home/End), plus Tab-out and
  // Esc closing it.
  keydown(event) {
    if (!this.menu) return

    if (event.key === "Escape") {
      event.preventDefault()
      this.escape(event)
      return
    }
    if (event.key === "Tab") {
      // close() returns focus to the trigger, so the browser's own Tab then
      // moves to whatever follows the kebab rather than to a detached item.
      this.close()
      return
    }
    const items = this.#focusableItems()
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

  // A suggestion resolved somewhere (this menu, another surface, the reject
  // modal). Remember it so a menu built later for the same suggestion opens
  // already terminal, and update an open menu in place.
  onResolved(event) {
    const { suggestionId, outcome } = event.detail || {}
    if (!suggestionId) return

    this.resolved.set(suggestionId, outcome === "rejected" ? "✓ Rejected" : "✓ Approved")
    if (this.menu) this.#markResolved(this.menu)
  }

  // private

  #open(trigger, { focusFirst }) {
    const build = BUILDERS[trigger.dataset.menu]
    const items = build ? build(trigger, this.pathsValue) : []
    if (!items.length) return

    const menu = document.createElement("div")
    menu.className = MENU_CLASSES
    menu.setAttribute("role", "menu")
    menu.setAttribute("aria-orientation", "vertical")
    const label = trigger.getAttribute("aria-label")
    if (label) menu.setAttribute("aria-label", label)
    menu.dataset.explorerMenu = trigger.dataset.menu
    // A menu item that opens a modal is torn down with the menu, so the dialog
    // has no surviving invoker to hand focus back to on close (its own
    // re-resolution paths all assume a `Kit::Dropdown`). Name the trigger as
    // the durable return target — `modal_controller` reads this.
    const returnId = this.#ensureId(trigger)
    items.forEach((item) => {
      const node = this.#build(item)
      node.querySelectorAll?.("[role='menuitem']").forEach((el) => {
        el.dataset.modalFocusReturn = returnId
      })
      if (node.matches?.("[role='menuitem']")) node.dataset.modalFocusReturn = returnId
      menu.appendChild(node)
    })
    this.#markResolved(menu)

    // Inserted next to its trigger — NOT at the root — so a menu item can still
    // reach the entity it belongs to (`field-editor#open` resolves its host by
    // `closest("[data-editor-action]")`, `reorder-list#moveUp` by
    // `closest("[data-reorder-item-id]")`). `position: fixed` keeps it out of
    // the matrix's scroll clipping regardless.
    this.#liftStackingContext(trigger)
    trigger.insertAdjacentElement("afterend", menu)
    // Acting on a menu item closes it — every item is a one-shot action.
    // Approve is the exception: it swaps itself to "✓ Approved" in place, which
    // is the actor's only immediate feedback. Capture phase because
    // `reorder-move#move` stops propagation, deferred by a task so the item's
    // own Stimulus action runs before the menu is torn down.
    menu.addEventListener("click", (event) => {
      if (event.target.closest("[data-action~='suggestion-action#approve']")) return

      setTimeout(() => this.close(), 0)
    }, true)

    this.menu = menu
    this.openTrigger = trigger
    trigger.setAttribute("aria-expanded", "true")

    this.#position()
    window.addEventListener("scroll", this._onScroll, true)
    window.addEventListener("resize", this._onScroll)
    if (focusFirst) this.#focusableItems()[0]?.focus()
  }

  // Focus never dies with the menu: if it is still inside when we tear down —
  // a Tab out, an item that opened no dialog — it goes back to the trigger, the
  // APG menu-button contract. A menu item that moved focus somewhere deliberate
  // (the shared editor's textarea, an open dialog) keeps it.
  #returnFocus() {
    if (!this.menu?.contains(document.activeElement)) return

    this.openTrigger?.focus()
  }

  #ensureId(element) {
    if (!element.id) element.id = `explorer-menu-trigger-${(idSeed += 1)}`

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

  // See LIFTED_Z. Walks to the nearest ancestor that creates a stacking context
  // (positioned + an explicit z-index) and raises it, remembering the inline
  // value so close() can put it back exactly as it was.
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

  #build(item) {
    if (item.group) return this.#buildGroup(item)

    return this.#buildItem(item)
  }

  #buildItem({ label, tone, data }) {
    const button = document.createElement("button")
    button.type = "button"
    button.setAttribute("role", "menuitem")
    button.className = `explorer-menu-item${tone ? ` explorer-menu-item--${tone}` : ""}`
    button.textContent = label
    applyData(button, data)
    return button
  }

  // The approve/reject pair. `role="none"` because a plain div interrupting the
  // menuitem ancestry would break the ARIA menu contract.
  #buildGroup({ sid, data, items }) {
    const wrapper = document.createElement("div")
    wrapper.setAttribute("role", "none")
    wrapper.dataset.menuSuggestionId = sid
    applyData(wrapper, data)
    items.forEach((item) => wrapper.appendChild(this.#build(item)))
    return wrapper
  }

  // A stale menu must never offer an actionable Approve/Reject for a suggestion
  // that already resolved (Hard-Won Lesson 23).
  #markResolved(root) {
    root.querySelectorAll("[data-menu-suggestion-id]").forEach((group) => {
      const label = this.resolved.get(group.dataset.menuSuggestionId)
      if (!label) return

      const approve = group.querySelector("[data-action~='suggestion-action#approve']")
      if (approve) approve.textContent = label
      group.querySelectorAll("button").forEach((button) => { button.disabled = true })
    })
  }

  #focusableItems() {
    if (!this.menu) return []

    return Array.from(this.menu.querySelectorAll("[role='menuitem']")).filter((el) => !el.disabled)
  }

  // A fixed menu doesn't move with its trigger, so follow the trigger on any
  // scroll (window or a nested pane) rather than dismissing — a menu that
  // vanishes because the page shifted a pixel is the worse failure.
  #onScroll() {
    // A surgical Turbo Stream can replace the frame the menu was built into —
    // drop the stale reference (and its listeners) rather than reposition it.
    if (!this.menu?.isConnected || !this.openTrigger?.isConnected) {
      this.close()
      return
    }
    this.#position()
  }

  // Anchored to the trigger, clamped into the viewport, flipped above when
  // there is more room there.
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

// ── Item builders — one per `data-menu` kind ──
//
// Each returns a plain list of item descriptors; nothing here reaches the DOM
// except to read coordinates the grid already publishes.

const BUILDERS = {
  capability(trigger, paths) {
    const data = trigger.dataset
    const row = trigger.closest("[data-capability-id]")
    const id = row?.dataset.capabilityId
    const name = row?.dataset.capabilityName || ""
    const items = []

    if (data.menuNameSid) {
      items.push(approvalGroup(paths, data.menuNameSid, "capabilityName", data.menuNamePreview))
    }
    if (data.menuDescSid) {
      items.push(
        approvalGroup(paths, data.menuDescSid, "capabilityDescription", data.menuDescPreview)
      )
    }
    items.push(editItem("Edit name…", `capability-name-${id}`))
    items.push(editItem("Edit description…", `capability-description-${id}`))
    items.push(discussItem({
      "discuss-capability-id": id,
      "discuss-context-label": name,
      "discuss-level-options": JSON.stringify(
        (data.menuLevels || "").split(",").filter(Boolean)
          .map((ordinal) => ({ ordinal: Number(ordinal), label: `L${ordinal}` }))
      )
    }))
    capabilityMoveItems(items, trigger, paths.capabilityReorder, id, data)
    if (data.menuBindings) {
      items.push(modalItem("Edit roles…", "binding-editor-modal", {
        "binding-editor-capability-id": id,
        "binding-editor-capability-name": name
      }))
    }
    if (data.menuArchive) {
      items.push(modalItem("Archive…", "archive-capability-modal", {
        "archive-capability-id": id,
        "archive-capability-name": name,
        "archive-stable-id": data.menuStable,
        "archive-needs-mapping": data.menuMapping
      }))
    }
    return items
  },

  expectation(trigger, paths) {
    const data = trigger.dataset
    const row = trigger.closest("[data-capability-id]")
    const context = [row?.dataset.capabilityName, `L${data.menuLevel}`].filter(Boolean).join(" · ")
    const items = []

    if (data.menuSid) {
      items.push(approvalGroup(paths, data.menuSid, "expectation", data.menuPreview))
    }
    items.push(editItem("Edit expectation…", `expectation-text-${data.menuExpectation}`))
    items.push(discussItem({
      "discuss-capability-id": row?.dataset.capabilityId,
      "discuss-level-ordinal": data.menuLevel,
      "discuss-context-label": context
    }))
    return items
  },

  illustration(trigger, paths) {
    const data = trigger.dataset
    const id = trigger.closest("[data-reorder-item-id]")?.dataset.reorderItemId
    const items = []

    if (data.menuSid) {
      items.push(approvalGroup(paths, data.menuSid, "illustration", data.menuPreview))
    }
    items.push(editItem("Edit example…"))
    items.push(discussItem({
      "discuss-illustration-id": id,
      "discuss-context-label": data.menuContext
    }))
    // The enclosing UL's `reorder-list` controller resolves the neighbour from
    // DOM order and moves this frame's node in place on success — no matrix
    // refresh, so the expanded row and the scroll position survive. Offer only
    // the directions that exist, like every other menu's Move items; position is
    // read from the DOM at open time (NOT from a server flag), because an
    // in-place move changes the order without re-rendering the trigger.
    if (data.menuMove) {
      const siblings = reorderSiblings(trigger)
      const index = siblings.indexOf(trigger.closest("[data-reorder-item-id]"))
      if (index > 0) items.push({ label: "Move up", data: { action: "reorder-list#moveUp" } })
      if (index >= 0 && index < siblings.length - 1) {
        items.push({ label: "Move down", data: { action: "reorder-list#moveDown" } })
      }
    }
    items.push(modalItem("Archive…", "archive-illustration-modal", {
      "archive-illustration-id": id,
      "archive-illustration-label": data.menuContext
    }))
    return items
  },

  category(trigger, paths) {
    const data = trigger.dataset
    const header = trigger.closest("[data-category-id]")
    const id = header?.dataset.categoryId
    const items = [
      editItem("Edit name…", `category-name-${id}`),
      editItem("Edit description…", `category-description-${id}`)
    ]
    categoryMoveItems(items, trigger, paths.categoryReorder, id, data)
    if (data.menuArchive) {
      items.push(modalItem("Archive…", "archive-category-modal", {
        "archive-category-id": id,
        "archive-category-name": data.menuName
      }))
    }
    return items
  },

  "expectation-create": (trigger, paths) => createSuggestionMenu(trigger, paths, "expectation-create"),
  "illustration-create": (trigger, paths) => createSuggestionMenu(trigger, paths, "illustration-create")
}

function createSuggestionMenu(trigger, paths, kind) {
  const { menuSid, menuPreview } = trigger.dataset
  return menuSid ? [approvalGroup(paths, menuSid, kind, menuPreview)] : []
}

function approvalGroup(paths, sid, kind, preview) {
  const [changeLabel, entityLabel] = SUGGESTION_LABELS[kind]
  return {
    group: true,
    sid,
    data: {
      controller: "suggestion-action",
      "suggestion-action-approve-url-value": (paths.approve || "").replace(":id", sid),
      "suggestion-action-suggestion-id-value": sid,
      action: "suggestion:resolved@window->suggestion-action#onResolved"
    },
    items: [
      {
        label: `Approve ${changeLabel}`,
        tone: "approve",
        data: { action: "suggestion-action#approve" }
      },
      modalItem(`Reject ${changeLabel}`, "reject-suggestion-modal", {
        "reject-suggestion-id": sid,
        "reject-entity-label": entityLabel,
        "reject-preview": preview || ""
      })
    ]
  }
}

// The kebab's stand-in for the hover pencil — the only way to reach it on a
// touch device, where the cluster collapses to the kebab. The pencils live
// inside their own Turbo Frames (so a frame swap re-renders them) while the
// kebab does not, hence the frame id for everything but the illustration (whose
// kebab IS inside its editor host).
function editItem(label, hostFrame) {
  return {
    label,
    data: { action: "field-editor#open", "editor-host-frame": hostFrame }
  }
}

function discussItem(anchor) {
  return modalItem("Discuss…", "request-clarification-modal", anchor)
}

function modalItem(label, modalId, data) {
  return { label, data: { action: "click->modal#open", "modal-target-id": modalId, ...data } }
}

// Move up / Move down for a capability, relative to the MOVABLE rows the viewer
// can see inside this capability's category `<tbody>`. Position is read from the
// DOM at open time, never from a server-sent neighbour id: `reorder-move` now
// repositions the rows in place (no matrix refresh), so a server flag would be
// stale from the first move onwards — the same reason the illustration menu
// already reads its own position (§11a).
function capabilityMoveItems(items, trigger, url, id, data) {
  if (!data.menuMove || !id) return

  const row = trigger.closest("tr[data-capability-id]")
  const siblings = Array.from(
    row?.closest("tbody")?.querySelectorAll("tr[data-capability-id][data-movable='true']") || []
  )
  pushMoveItems(items, url, "capability", id, siblings.indexOf(row), siblings, (el) =>
    el.dataset.capabilityId
  )
}

// The same rule for a category — siblings are the `<tbody>` groups of the table.
function categoryMoveItems(items, trigger, url, id, data) {
  if (!data.menuMove || !id) return

  const group = trigger.closest("tbody[data-category-group]")
  const siblings = Array.from(
    group?.parentElement?.querySelectorAll("tbody[data-category-group]") || []
  )
  pushMoveItems(items, url, "category", id, siblings.indexOf(group), siblings, (el) =>
    el.dataset.categoryGroup
  )
}

function pushMoveItems(items, url, scope, id, index, siblings, idOf) {
  if (index < 0) return

  if (index > 0) {
    items.push(moveItem("Move up", url, scope, id, idOf(siblings[index - 1]), "before"))
  }
  if (index < siblings.length - 1) {
    items.push(moveItem("Move down", url, scope, id, idOf(siblings[index + 1]), "after"))
  }
}

function moveItem(label, url, scope, id, targetId, placement) {
  const key = scope === "category" ? "category_id" : "capability_id"
  return {
    label,
    data: {
      controller: "reorder-move",
      "reorder-move-url-value": url,
      "reorder-move-scope-value": scope,
      "reorder-move-body-value": JSON.stringify({
        reorder: { [key]: id, target_id: targetId, placement }
      }),
      action: "reorder-move#move"
    }
  }
}

// The items `reorder-list` itself would move between — same list, same
// selector, so the menu can never offer a direction the controller no-ops.
function reorderSiblings(trigger) {
  const list = trigger.closest("[data-controller~='reorder-list']")
  return list ? Array.from(list.querySelectorAll("[data-reorder-item-id]")) : []
}

function applyData(element, data) {
  Object.entries(data || {}).forEach(([name, value]) => {
    if (value == null || value === "") return

    element.setAttribute(`data-${name}`, String(value))
  })
}

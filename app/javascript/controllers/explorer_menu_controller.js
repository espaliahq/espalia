// The framework explorer's kebab menus, on the shared `delegated-menu`
// controller ([#380](https://github.com/espaliahq/espalia/issues/380)). Mounted once on the explorer root. The grid ships a bare
// trigger carrying only its entity's ids, and this builds the items on open
// from the trigger's dataset plus the coordinates the grid already publishes
// (`tr[data-capability-id]`, `tr[data-capability-name]`, `tr[data-category-id]`).
//
// Trigger contract:
//
//   data-menu            capability | expectation | illustration | category |
//                        expectation-create | illustration-create
//   data-menu-*          the ids and flags that kind needs (see BUILDERS)
//
// Built items keep the `data-*` the real behaviour needs, so they drive the
// same controllers as ever: `modal#open`, `field-editor#open`,
// `reorder-move#move`, `reorder-list#moveUp`, `suggestion-action#approve`.
//
// This controller outlives every menu, so it remembers which suggestions have
// resolved (the window `suggestion:resolved` event) and builds their
// approve and reject items already terminal (Hard-Won Lesson 23).

import DelegatedMenuController from "controllers/delegated_menu_controller"

// Reject-modal copy per suggestion kind: [what the verb acts on, what the modal
// calls the entity].
const SUGGESTION_LABELS = {
  capabilityName: ["name change", "capability name"],
  capabilityDescription: ["description change", "capability description"],
  expectation: ["expectation change", "expectation"],
  illustration: ["example change", "example"],
  "expectation-create": ["new expectation", "new expectation"],
  "illustration-create": ["new example", "new example"]
}

export default class extends DelegatedMenuController {
  static menuClasses = `explorer-menu ${DelegatedMenuController.menuClasses}`

  static values = {
    // { approve: "/frameworks/F/suggestions/:id/approve?inline=1", … } — path
    // templates so no Rails route is hand-written in JS.
    paths: { type: Object, default: {} }
  }

  connect() {
    super.connect()
    this.resolved = new Map()
  }

  // A suggestion resolved somewhere (this menu, another surface, the reject
  // modal). Remember it so a menu built later opens already terminal, and
  // update an open menu in place.
  onResolved(event) {
    const { suggestionId, outcome } = event.detail || {}
    if (!suggestionId) return

    this.resolved.set(suggestionId, outcome === "rejected" ? "✓ Rejected" : "✓ Approved")
    if (this.menu) this.#markResolved(this.menu)
  }

  items(trigger) {
    const build = BUILDERS[trigger.dataset.menu]
    return (build ? build(trigger, this.pathsValue) : []).map((item) => this.#build(item))
  }

  opened(menu, trigger) {
    menu.dataset.explorerMenu = trigger.dataset.menu
    this.#markResolved(menu)
  }

  // Approve swaps itself to "✓ Approved" in place, the actor's only immediate
  // feedback, so it leaves the menu open.
  keepsOpen(target) {
    return Boolean(target.closest("[data-action~='suggestion-action#approve']"))
  }

  // private

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

// Drag a person or a position on the scenario map to move it. A person drops
// on another unit, on Unassigned, or on a position to fill it, and someone in
// a position can drop on its own unit to hold a place there instead; a
// position drops on another unit. A drop clicks the dragged row's own "Move…" button
// with the destination in `data-move-to`, so the dialog that confirms the move
// is the one the keyboard path opens.
//
// On the timeline a drop cell is one unit in one step (`data-map-step`), and a
// bar covers a span of steps (`data-map-from-step`, `data-map-to-step`). A cell
// takes a bar only in a step the bar covers, and the drop opens that step's
// dialog, `move-person-modal-<step>`. While a drag is on, the controller's
// element carries `data-dragging`, so bars can step aside for the cells under them.
//
// Usage:
//   <div data-controller="map-move">
//     <section data-map-unit="<unit id>" data-action="dragover->map-move#over dragleave->map-move#leave drop->map-move#drop">
//       <li data-map-person="<person id>" data-map-drag="person" draggable="true" data-map-move-from="<unit id>"
//           data-action="dragstart->map-move#start dragend->map-move#end">
//         <button data-modal-target-id="move-person-modal" …>Move…</button>   (the row's other dialogs are ignored)
//       </li>
//       <div data-map-position="<position id>" data-map-drag="position" draggable="true" data-map-move-from="<unit id>"
//            data-action="dragstart->map-move#start … drop->map-move#drop">
//         <button aria-haspopup="menu" data-menu="position" …>⋮</button>   (its delegated menu holds Move…)
//       </div>
//     </section>
//   </div>

import BaseController from "controllers/base_controller"

const DIALOGS = { person: "move-person-modal", position: "move-position-modal" }
const UNASSIGNED = "unassigned"

export default class extends BaseController {
  start(event) {
    if (event.currentTarget !== event.target) return

    this.dragged = event.currentTarget
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", this.dragged.dataset.mapPerson || this.dragged.dataset.mapPosition)
    // Changing the page inside dragstart cancels the drag in Chrome.
    setTimeout(() => { if (this.dragged) this.element.dataset.dragging = "" })
  }

  end() {
    this.dragged = null
    delete this.element.dataset.dragging
    this.#clear()
  }

  over(event) {
    const target = event.currentTarget
    if (!this.#accepts(target)) return this.#refuse(event)

    event.preventDefault()
    event.stopPropagation()
    event.dataTransfer.dropEffect = "move"
    if (target.dataset.dropOver === undefined) {
      this.#clear()
      target.dataset.dropOver = ""
    }
  }

  leave(event) {
    if (event.currentTarget.contains(event.relatedTarget)) return

    delete event.currentTarget.dataset.dropOver
  }

  drop(event) {
    const target = event.currentTarget
    if (!this.#accepts(target)) return this.#refuse(event)

    event.preventDefault()
    event.stopPropagation()
    const { mapStep } = target.dataset
    const dialog = DIALOGS[this.dragged.dataset.mapDrag] + (mapStep === undefined ? "" : `-${mapStep}`)
    const row = this.dragged
    const destination = this.#destination(target)
    this.end()
    const trigger = row.querySelector(`[data-modal-target-id='${dialog}']`)
    if (trigger) return this.#openDialog(trigger, destination)

    // A position's Move… lives in its delegated menu, which exists only while
    // open. Stimulus binds a new element's actions from a MutationObserver,
    // so the item is clicked a task after the ⋮ builds it.
    row.querySelector("[aria-haspopup][data-menu]")?.click()
    setTimeout(() => {
      const item = row.querySelector(`[data-modal-target-id='${dialog}']`)
      if (item) this.#openDialog(item, destination)
    })
  }

  // private

  #openDialog(trigger, destination) {
    trigger.dataset.moveTo = destination
    trigger.click()
    delete trigger.dataset.moveTo
  }

  // A position sits inside its unit, so a drop refused on the position the
  // person already holds would otherwise land on the unit as a move.
  #refuse(event) {
    const { mapPosition } = event.currentTarget.dataset
    if (mapPosition && mapPosition === this.dragged?.dataset.mapMoveFromPosition) event.stopPropagation()
  }

  #accepts(target) {
    if (!this.dragged) return false
    const { mapDrag, mapMoveFrom, mapMoveFromPosition, mapFromStep, mapToStep } = this.dragged.dataset
    const step = target.dataset.mapStep
    if (step !== undefined && !(Number(mapFromStep) <= Number(step) && Number(step) <= Number(mapToStep))) return false
    if (target.dataset.mapPosition) return mapDrag === "person" && target.dataset.mapPosition !== mapMoveFromPosition

    const unit = target.dataset.mapUnit
    if (unit === mapMoveFrom && !mapMoveFromPosition) return false

    return mapDrag === "person" || unit !== UNASSIGNED
  }

  #destination(target) {
    return target.dataset.mapPosition ? `position:${target.dataset.mapPosition}` : target.dataset.mapUnit
  }

  #clear() {
    this.element.querySelectorAll("[data-drop-over]").forEach((target) => delete target.dataset.dropOver)
  }
}

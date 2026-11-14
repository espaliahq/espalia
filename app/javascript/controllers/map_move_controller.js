// Drag a person or a position on the scenario map to move it. A person drops
// on another unit, on Unassigned, or on a position to fill it, and someone in
// a position can drop on its own unit to hold a place there instead; a
// position drops on another unit. A drop clicks the dragged row's own "Move…" button
// with the destination in `data-move-to`, so the dialog that confirms the move
// is the one the keyboard path opens.
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
//         <button data-modal-target-id="move-position-modal" …>Move…</button>
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
  }

  end() {
    this.dragged = null
    this.#clear()
  }

  over(event) {
    const target = event.currentTarget
    if (!this.#accepts(target)) return

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
    if (!this.#accepts(target)) return

    event.preventDefault()
    event.stopPropagation()
    const trigger = this.dragged.querySelector(`[data-modal-target-id='${DIALOGS[this.dragged.dataset.mapDrag]}']`)
    this.end()
    trigger.dataset.moveTo = this.#destination(target)
    trigger.click()
    delete trigger.dataset.moveTo
  }

  // private

  #accepts(target) {
    if (!this.dragged) return false
    const { mapDrag, mapMoveFrom, mapMoveFromPosition } = this.dragged.dataset
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

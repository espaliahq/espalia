// Drag a person on the scenario map onto another unit, or onto Unassigned,
// to move them there. A drop clicks the row's own "Move…" button with the
// unit in `data-move-to`, so the dialog that sets the allocation is the one
// the keyboard path opens.
//
// Usage:
//   <div data-controller="map-move">
//     <section data-map-unit="<unit id>" data-action="dragover->map-move#over dragleave->map-move#leave drop->map-move#drop">
//       <li data-map-person="<person id>" draggable="true" data-map-move-from="<unit id>"
//           data-action="dragstart->map-move#start dragend->map-move#end">
//         <button data-modal-target-id="move-person-modal" …>Move…</button>   (the row's other dialogs are ignored)
//       </li>
//     </section>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  start(event) {
    this.dragged = event.currentTarget
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", this.dragged.dataset.mapPerson)
  }

  end() {
    this.dragged = null
    this.#clear()
  }

  over(event) {
    if (!this.#accepts(event.currentTarget)) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    event.currentTarget.dataset.dropOver = ""
  }

  leave(event) {
    if (event.currentTarget.contains(event.relatedTarget)) return

    delete event.currentTarget.dataset.dropOver
  }

  drop(event) {
    const unit = event.currentTarget
    if (!this.#accepts(unit)) return

    event.preventDefault()
    const trigger = this.dragged.querySelector("[data-modal-target-id='move-person-modal']")
    this.end()
    trigger.dataset.moveTo = unit.dataset.mapUnit
    trigger.click()
    delete trigger.dataset.moveTo
  }

  // private

  #accepts(unit) {
    return this.dragged && unit.dataset.mapUnit !== this.dragged.dataset.mapMoveFrom
  }

  #clear() {
    this.element.querySelectorAll("[data-drop-over]").forEach((unit) => delete unit.dataset.dropOver)
  }
}

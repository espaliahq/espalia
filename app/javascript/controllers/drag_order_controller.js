// Drags an ordered list, such as the pay bands or the cost-centre entries, into
// a new order on a desktop. The up and down buttons on each row work without
// it, and are the way on a phone or a keyboard.
//
// While a band is dragged, the rows move under the pointer. When the drag
// ends, the whole order goes to the server through the hidden form, with the
// order the page showed so a list moved since is refused. Turbo
// follows the redirect and the positions and "Never used" flags come back fresh.
// The order goes as `<field>[]`, and the order shown as `from_<field>[]`.
//
// Usage:
//   <div data-controller="drag-order" data-drag-order-field-value="pay_band_ids">
//     <form data-drag-order-target="form" action="/tenant/pay_bands/reorder" hidden>…</form>
//     <ol data-drag-order-target="list">
//       <li draggable="true" data-order-id="<id>"
//           data-action="pointerdown->drag-order#press dragstart->drag-order#start
//                        dragover->drag-order#over drop->drag-order#drop dragend->drag-order#end">…</li>
//     </ol>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["form", "list"]
  static values = { field: String }

  // A drag's target is the row, wherever in it the pointer went down, so the
  // control pressed is read here instead.
  press(event) {
    this.pressed = event.target
  }

  start(event) {
    if ((this.pressed ?? event.target).closest("button, a, input, select, form")) return event.preventDefault()

    this.dragged = event.currentTarget
    this.dropped = false
    this.before = [...this.listTarget.children]
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", this.dragged.dataset.orderId)
    // Changing the page inside dragstart cancels the drag in Chrome.
    setTimeout(() => { if (this.dragged) this.dragged.dataset.dragSource = "" })
  }

  over(event) {
    if (!this.dragged) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    const row = event.currentTarget
    if (row === this.dragged) return

    const { top, height } = row.getBoundingClientRect()
    row.parentNode.insertBefore(this.dragged, event.clientY < top + height / 2 ? row : row.nextSibling)
  }

  drop(event) {
    if (!this.dragged) return

    event.preventDefault()
    this.dropped = true
  }

  // The rows already stand where the drag left them, so that is the order
  // saved. A drag cancelled with Escape or dropped outside the list never
  // drops on a row, and the rows go back.
  end() {
    if (!this.dragged) return

    delete this.dragged.dataset.dragSource
    this.dragged = null
    if (!this.dropped) return this.listTarget.append(...this.before)

    this.#save()
  }

  // private

  #save() {
    const order = this.#order()
    const before = this.before.map((row) => row.dataset.orderId)
    if (order.join() === before.join()) return

    this.formTarget.querySelectorAll(`input[type='hidden'][name$='${this.fieldValue}[]']`).forEach((input) => input.remove())
    this.#fields(`${this.fieldValue}[]`, order)
    this.#fields(`from_${this.fieldValue}[]`, before)
    this.formTarget.requestSubmit()
  }

  #fields(name, ids) {
    ids.forEach((id) => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = name
      input.value = id
      this.formTarget.append(input)
    })
  }

  #order() {
    return [...this.listTarget.querySelectorAll("[data-order-id]")].map((row) => row.dataset.orderId)
  }
}

// Drags the pay bands into a new order on a desktop. The up and down buttons
// on each row work without it, and are the way on a phone or a keyboard.
//
// While a band is dragged, the rows move under the pointer. When the drag
// ends, the whole order goes to the server through the hidden form, so Turbo
// follows the redirect and the positions and "Never used" flags come back fresh.
//
// Usage:
//   <div data-controller="pay-band-order">
//     <form data-pay-band-order-target="form" action="/tenant/pay_bands/reorder" hidden>…</form>
//     <ol data-pay-band-order-target="list">
//       <li draggable="true" data-pay-band-id="<id>"
//           data-action="dragstart->pay-band-order#start dragover->pay-band-order#over
//                        drop->pay-band-order#drop dragend->pay-band-order#end">…</li>
//     </ol>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["form", "list"]

  start(event) {
    if (event.target.closest("button, a, input, select, form")) return event.preventDefault()

    this.dragged = event.currentTarget
    this.before = this.#order()
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", this.dragged.dataset.payBandId)
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
    if (this.dragged) event.preventDefault()
  }

  // The rows already stand where the drag left them, so that is the order saved.
  end() {
    if (!this.dragged) return

    delete this.dragged.dataset.dragSource
    this.dragged = null
    this.#save()
  }

  // private

  #save() {
    const order = this.#order()
    if (order.join() === this.before.join()) return

    this.formTarget.querySelectorAll("[name='pay_band_ids[]']").forEach((input) => input.remove())
    order.forEach((id) => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "pay_band_ids[]"
      input.value = id
      this.formTarget.append(input)
    })
    this.formTarget.requestSubmit()
  }

  #order() {
    return [...this.listTarget.querySelectorAll("[data-pay-band-id]")].map((row) => row.dataset.payBandId)
  }
}

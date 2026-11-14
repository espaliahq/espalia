// Points the plan page's shared "Rename scenario" dialog at the scenario whose
// control opened it, read from the trigger's dataset on the window
// `modal:open` event, and seeds the field with its current name.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["name"]

  connect() {
    super.connect()
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
    super.disconnect()
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    if (data.scenarioRenameAction === undefined) return

    this.element.action = data.scenarioRenameAction
    this.nameTarget.value = data.scenarioRenameName || ""
    requestAnimationFrame(() => this.nameTarget.select())
  }
}

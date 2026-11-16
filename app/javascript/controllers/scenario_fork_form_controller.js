// Sets up the plan page's shared "New scenario" dialog from the control that
// opened it: the scenario it starts from comes in the trigger's dataset on the
// window `modal:open` event. The plan refuses a second scenario after the same
// one, and an alternative to today, so those choices are switched off here
// first; an alternative keeps its parent's period, so it takes no end date.
// Only a step after today takes a start, since every later step starts the
// day after the one before it ends.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["parent", "relation", "endsOn", "endsOnField", "startsOn", "startsOnField", "blocked", "submit"]
  static values = { baseline: String }

  connect() {
    super.connect()
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
    this.sync()
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
    super.disconnect()
  }

  sync() {
    const option = this.parentTarget.selectedOptions[0]
    const then = this.#relation("then")
    const instead = this.#relation("instead")
    then.disabled = option?.dataset.followed === "true"
    instead.disabled = this.parentTarget.value === this.baselineValue

    if (then.disabled && !instead.disabled) instead.checked = true
    if (instead.disabled && !then.disabled) then.checked = true

    const blocked = then.disabled && instead.disabled
    this.blockedTarget.hidden = !blocked
    this.submitTarget.disabled = blocked

    const following = then.checked && !then.disabled
    this.endsOnFieldTarget.hidden = !following
    this.endsOnTarget.disabled = !following

    const first = following && this.parentTarget.value === this.baselineValue
    this.startsOnFieldTarget.hidden = !first
    this.startsOnTarget.disabled = !first
  }

  // private

  #relation(value) {
    return this.relationTargets.find((radio) => radio.value === value)
  }

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    if (data.scenarioForkParent === undefined) return

    this.element.reset()
    this.parentTarget.value = data.scenarioForkParent
    this.sync()
  }
}

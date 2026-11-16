// Sets up the plan page's shared "New scenario" dialog from the control that
// opened it: the scenario it starts from comes in the trigger's dataset on the
// window `modal:open` event. The plan refuses a second scenario after the same
// one, and an alternative to today, so those choices are switched off here
// first; an alternative keeps its parent's period, so it takes no end date.
// Every later step starts the day after the one before it ends, so only a
// step after today, or after a step with no end date, takes a start.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["parent", "relation", "endsOn", "endsOnField", "noEnd", "startsOn", "startsOnField", "firstHint", "openHint", "blocked", "submit"]
  static values = { baseline: String }

  connect() {
    super.connect()
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
    this.baseOn = this.startsOnTarget.defaultValue
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
    this.noEndTarget.disabled = !following
    this.endsOnTarget.disabled = !following || this.noEndTarget.checked

    const first = following && this.parentTarget.value === this.baselineValue
    const afterOpen = following && option?.dataset.open === "true"
    this.#start(first ? "first" : afterOpen ? "open" : null, option)
  }

  // private

  #start(kind, option) {
    const field = this.startsOnTarget
    this.startsOnFieldTarget.hidden = !kind
    field.disabled = !kind
    field.required = kind === "open"
    this.firstHintTarget.hidden = kind !== "first"
    this.openHintTarget.hidden = kind !== "open"
    if (kind) field.setAttribute("aria-describedby", (kind === "first" ? this.firstHintTarget : this.openHintTarget).id)

    field.min = kind === "open" ? option.dataset.earliestStart : this.baseOn
    if (kind === this.startKind) return
    this.startKind = kind
    field.value = kind === "open" ? "" : this.baseOn
  }

  #relation(value) {
    return this.relationTargets.find((radio) => radio.value === value)
  }

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    if (data.scenarioForkParent === undefined) return

    this.element.reset()
    this.startKind = undefined
    this.parentTarget.value = data.scenarioForkParent
    this.sync()
  }
}

// Evidence-specific companion to the generic `modal` controller.
//
// Visibility (open/close/click-outside/scroll-lock) lives in `modal`. This
// controller only prefills the shared evidence modal for whichever (capability,
// level) cell triggered it, manages the optional "also applies to other
// capabilities" picker, and toggles the custom-type label.
//
// Mounted on the assessment page wrapper alongside `modal`:
//   <div data-controller="modal evidence-form"
//        data-action="modal:open@window->evidence-form#prefill">
//
// The per-cell trigger opens the shared modal and carries the coords:
//   <button data-action="click->modal#open"
//           data-evidence-form-capability-stable-id-param="<uuid>"
//           data-evidence-form-level-ordinal-param="3">+ Add evidence</button>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = [
    "form", "capabilityField", "levelField", "typeSelect", "customLabelWrapper",
    "linkCapabilitySelect", "linkLevelSelect", "additionalLinks"
  ]

  // Reacts to the modal:open event the `modal` controller dispatches. Reads the
  // coords from the trigger's dataset (carried on event.detail.dataset). No-ops
  // for modal opens that aren't evidence (e.g. the delegation modal).
  prefill(event) {
    const dataset = event.detail?.dataset || {}
    const capabilityStableId = dataset.evidenceFormCapabilityStableIdParam
    const levelOrdinal = dataset.evidenceFormLevelOrdinalParam
    if (!capabilityStableId || levelOrdinal == null || levelOrdinal === "") return

    this.formTarget.reset()
    this.capabilityFieldTarget.value = capabilityStableId
    this.levelFieldTarget.value = levelOrdinal
    this.clearAdditionalLinks()
    this.syncCustomLabel()
  }

  // Appends the currently-selected capability × level as an additional
  // link: a removable chip plus a hidden `evidence[additional_links][]`
  // input carrying the "<capability_stable_id>|<level_ordinal>" token the
  // controller parses. Skips duplicates of the primary cell or an
  // already-added pair.
  addLink() {
    if (!this.hasLinkCapabilitySelectTarget || !this.hasAdditionalLinksTarget) return
    const cap = this.linkCapabilitySelectTarget.value
    const level = this.linkLevelSelectTarget.value
    if (!cap || !level) return

    const token = `${cap}|${level}`
    if (token === `${this.capabilityFieldTarget.value}|${this.levelFieldTarget.value}`) return
    if (this.additionalLinksTarget.querySelector(`input[value="${token}"]`)) return

    const capLabel = this.linkCapabilitySelectTarget.selectedOptions[0]?.textContent?.trim() || cap
    const chip = document.createElement("span")
    chip.className =
      "inline-flex items-center gap-1 rounded bg-gray-100 dark:bg-gray-700 px-2 py-0.5 " +
      "text-[11px] text-gray-700 dark:text-gray-200"
    chip.dataset.token = token
    chip.textContent = `${capLabel} · L${level}`

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "ml-0.5 text-gray-400 hover:text-gray-700 dark:hover:text-gray-200"
    remove.textContent = "×"
    remove.setAttribute("aria-label", "Remove link")
    remove.dataset.action = "click->evidence-form#removeLink"

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = "evidence[additional_links][]"
    hidden.value = token

    chip.appendChild(remove)
    chip.appendChild(hidden)
    this.additionalLinksTarget.appendChild(chip)
  }

  removeLink(event) {
    event.target.closest("[data-token]")?.remove()
  }

  clearAdditionalLinks() {
    if (this.hasAdditionalLinksTarget) this.additionalLinksTarget.replaceChildren()
  }

  typeChanged() {
    this.syncCustomLabel()
  }

  // private

  syncCustomLabel() {
    const isOther = this.typeSelectTarget.value === "other"
    this.customLabelWrapperTarget.classList.toggle("hidden", !isOther)
    const inputs = this.customLabelWrapperTarget.querySelectorAll("input")
    inputs.forEach((input) => { input.required = isOther })
  }
}

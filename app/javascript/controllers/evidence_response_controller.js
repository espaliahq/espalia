// Evidence-hub respond form: reveals the custom-type label field only when the
// selected evidence type is "other" (mirrors the evidence modal's behaviour
// without the modal's prefill coupling).
//
// Usage:
//   <div data-controller="evidence-response">
//     <select data-evidence-response-target="typeSelect"
//             data-action="change->evidence-response#typeChanged">…</select>
//     <div data-evidence-response-target="customLabel" class="hidden">…</div>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["typeSelect", "customLabel"]

  connect() {
    super.connect()
    this.#sync()
  }

  typeChanged() {
    this.#sync()
  }

  // private

  #sync() {
    if (!this.hasTypeSelectTarget || !this.hasCustomLabelTarget) return

    this.customLabelTarget.classList.toggle("hidden", this.typeSelectTarget.value !== "other")
  }
}

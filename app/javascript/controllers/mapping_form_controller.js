// Toggles the "surviving capability" field on the archive form based on the
// selected migration-mapping type — a survivor is only meaningful for
// evolved/split mappings, not for a plain archive.
//
// Usage:
//   <form data-controller="mapping-form">
//     <select data-mapping-form-target="type"
//             data-action="change->mapping-form#typeChanged">…</select>
//     <div data-mapping-form-target="survivor">…</div>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["type", "survivor"]
  static values = { survivorTypes: { type: Array, default: ["evolved", "split"] } }

  connect() {
    this.typeChanged()
  }

  typeChanged() {
    if (!this.hasSurvivorTarget || !this.hasTypeTarget) return

    const needsSurvivor = this.survivorTypesValue.includes(this.typeTarget.value)
    this.survivorTarget.classList.toggle("hidden", !needsSurvivor)
  }
}

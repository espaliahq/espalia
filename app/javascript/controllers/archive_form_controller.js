// Prefills the shared archive modal from the row-actions kebab that opened it.
//
// On the window `modal:open` event (dispatched by the modal controller with the
// trigger's dataset), it copies the capability id/name into the form, shows the
// migration-mapping section only for a pre-draft capability, and toggles the
// "surviving capability" select to whether the chosen mapping type needs one
// (Evolve does; Archive does not).
//
// Usage:
//   <form data-controller="archive-form">
//     <input data-archive-form-target="capabilityId">
//     <span  data-archive-form-target="title"></span>
//     <div   data-archive-form-target="mappingSection" class="hidden">
//       <select data-archive-form-target="type"
//               data-action="change->archive-form#typeChanged"></select>
//       <div data-archive-form-target="survivor">…</div>
//     </div>
//   </form>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["capabilityId", "title", "mappingSection", "type", "survivor"]
  static values = { survivorTypes: { type: Array, default: ["evolved"] } }

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  typeChanged() {
    if (!this.hasSurvivorTarget) return
    const needsSurvivor =
      this._mappingActive && this.hasTypeTarget && this.survivorTypesValue.includes(this.typeTarget.value)
    this.survivorTarget.classList.toggle("hidden", !needsSurvivor)
    // Disabled controls don't submit — so a hidden survivor never sends a
    // stale to_stable_id (e.g. after switching Evolve → Archive).
    const select = this.survivorTarget.querySelector("select")
    if (select) select.disabled = !needsSurvivor
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to archive-kebab triggers (others share the modal:open bus).
    if (data.archiveCapabilityId === undefined) return

    this.capabilityIdTarget.value = data.archiveCapabilityId || ""
    if (this.hasTitleTarget) {
      this.titleTarget.textContent = data.archiveCapabilityName || "this capability"
    }
    // A capability added in the current draft needs no migration mapping; hide
    // AND disable the mapping controls so they don't submit a spurious mapping
    // (a hidden-but-enabled select still posts its value).
    this._mappingActive = data.archiveNeedsMapping === "true"
    if (this.hasMappingSectionTarget) {
      this.mappingSectionTarget.classList.toggle("hidden", !this._mappingActive)
    }
    if (this.hasTypeTarget) this.typeTarget.disabled = !this._mappingActive
    this.#hideSelfFromSurvivors(data.archiveStableId)
    this.typeChanged()
  }

  // The shared survivor list contains every capability; a capability can't be
  // its own survivor, so hide its option for the one being archived.
  #hideSelfFromSurvivors(stableId) {
    if (!this.hasSurvivorTarget || !stableId) return
    const select = this.survivorTarget.querySelector("select")
    if (!select) return
    select.querySelectorAll("option").forEach((opt) => {
      opt.hidden = opt.value === stableId
      if (opt.hidden) opt.selected = false
    })
  }
}

// Drives the "request evidence" modal.
//
// Two roles, same controller class (mirrors evidence_modal):
//   - PAGE instance (on the wrapper with `modal`): `load` points the lazy
//     `#evidence-request-modal` frame at the render endpoint for the clicked
//     cell, so the server renders the form with that cell's context + suggestions.
//   - IN-FRAME instance (on the rendered form): `search` debounces the typeahead
//     and repoints the `#request-candidates` frame; `add`/`remove` manage the
//     selected recipients (client-side chips + `requestee_ids[]` hidden inputs).
//
// Usage (page trigger):
//   <button data-action="request-evidence#load click->modal#open"
//           data-modal-target-id="evidence-request-modal-overlay"
//           data-request-evidence-assignment-id-param="…"
//           data-request-evidence-capability-stable-id-param="…"
//           data-request-evidence-level-ordinal-param="3">Request evidence</button>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["frame", "search", "results", "selected", "ids", "empty", "submit", "label", "suggestions"]
  static values = { candidatesUrl: String }

  // PAGE: point the lazy frame at the assignment-scoped modal render endpoint.
  load(event) {
    if (!this.hasFrameTarget) return
    const p = event.params || {}
    if (!p.assignmentId) return
    const q = new URLSearchParams()
    if (p.capabilityStableId) q.set("capability_stable_id", p.capabilityStableId)
    if (p.levelOrdinal != null && p.levelOrdinal !== "") q.set("level_ordinal", p.levelOrdinal)
    this.frameTarget.src = `/assessments/${p.assignmentId}/evidence_request_modal?${q.toString()}`
  }

  // IN-FRAME: debounce keystrokes, then repoint the results frame at the query.
  search() {
    clearTimeout(this._t)
    this._t = setTimeout(() => this.#runSearch(), 250)
  }

  #runSearch() {
    const results = this.#resultsFrame()
    if (!results) return
    const q = (this.searchTarget.value || "").trim()
    const url = new URL(this.candidatesUrlValue, window.location.origin)
    url.searchParams.set("q", q)
    results.src = url.toString()
  }

  // IN-FRAME: add a candidate to the selection (idempotent on person id).
  add(event) {
    const { personId, name } = event.params || {}
    if (!personId || this.#selectedIds().includes(personId)) return

    this.idsTarget.appendChild(this.#hiddenInput(personId))
    this.selectedTarget.appendChild(this.#chip(personId, name))
    if (this.hasEmptyTarget) this.emptyTarget.classList.add("hidden")
    this.#toggleSuggestion(personId, false) // drop it from the suggestion list
    this.#refreshCount()
  }

  // IN-FRAME: remove a chip + its hidden input; restore its suggestion if any.
  remove(event) {
    const id = event.params?.personId
    if (!id) return
    this.element.querySelectorAll(`input[data-person-id="${id}"], span[data-person-id="${id}"]`)
      .forEach((el) => el.remove())
    this.#toggleSuggestion(id, true)
    if (this.hasEmptyTarget && this.#selectedIds().length === 0) this.emptyTarget.classList.remove("hidden")
    this.#refreshCount()
  }

  // private

  #resultsFrame() {
    return this.hasResultsTarget ? this.resultsTarget : this.element.querySelector("turbo-frame#request-candidates")
  }

  #selectedIds() {
    return Array.from(this.idsTarget.querySelectorAll("input")).map((i) => i.value)
  }

  // Build the hidden id input + the removable chip via DOM methods (textContent
  // escapes automatically) — never string-interpolate person data into HTML.
  #hiddenInput(personId) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = "evidence_request[requestee_ids][]"
    input.value = personId
    input.dataset.personId = personId
    return input
  }

  #chip(personId, name) {
    const chip = document.createElement("span")
    chip.className = "inline-flex items-center gap-1 min-h-9 px-2.5 rounded-full bg-primary/10 text-primary text-xs font-medium"
    chip.dataset.personId = personId
    chip.append(name || "")

    const remove = document.createElement("button")
    remove.type = "button"
    remove.setAttribute("aria-label", "Remove")
    remove.className = "leading-none text-primary/70 hover:text-primary cursor-pointer"
    remove.dataset.action = "request-evidence#remove"
    remove.dataset.requestEvidencePersonIdParam = personId
    remove.textContent = "×"
    chip.appendChild(remove)
    return chip
  }

  // Hide (show=false) or restore (show=true) a person's suggestion chip. Use an
  // inline display style, not a `hidden` class: the chip already carries an
  // `inline-flex` display utility, and Tailwind's `hidden` ties it on specificity
  // (source order wins, so the class wouldn't reliably hide it). Inline style does.
  #toggleSuggestion(personId, show) {
    if (!this.hasSuggestionsTarget) return
    this.suggestionsTarget
      .querySelectorAll(`[data-request-evidence-person-id-param="${personId}"]`)
      .forEach((el) => { el.style.display = show ? "" : "none" })
  }

  #refreshCount() {
    const n = this.#selectedIds().length
    if (this.hasLabelTarget) this.labelTarget.textContent = n === 0 ? "Send requests" : `Send ${n} ${n === 1 ? "request" : "requests"}`
    if (this.hasSubmitTarget) this.submitTarget.disabled = n === 0
  }
}

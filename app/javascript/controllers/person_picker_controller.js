// Reusable person picker: debounced typeahead search backed by a
// server-rendered turbo-frame of candidates, plus client-side selection
// chips that submit as hidden inputs. Extracted from the evidence-request
// modal's recipient picker (`request_evidence_controller` now extends
// this class) so any form can reuse the interaction.
//
// All identifier-sensitive wiring (action names, data-params, target
// attributes) derives from `this.identifier`, so subclasses registered
// under their own name (e.g. `request-evidence`) work without overrides.
//
// Example usage (typically rendered by Views::Shared::PersonPicker):
// <div data-controller="person-picker"
//      data-person-picker-candidates-url-value="/calibration_sessions/participant_candidates"
//      data-person-picker-field-name-value="calibration_session[participant_ids][]"
//      data-person-picker-frame-id-value="person-picker-candidates">
//   <input type="search" data-person-picker-target="search"
//          data-action="input->person-picker#search">
//   <turbo-frame id="person-picker-candidates" data-person-picker-target="results">…</turbo-frame>
//   <div data-person-picker-target="selected">…chips…</div>
//   <div data-person-picker-target="ids" class="hidden">…hidden inputs…</div>
// </div>
// Candidate rows/suggestions dispatch `<identifier>#add` with
// `-person-id-param` / `-name-param` data params.

import BaseController from "controllers/base_controller"
import { useDebounce } from "stimulus-use"

export default class extends BaseController {
  static targets = ["search", "results", "selected", "ids", "empty", "suggestions"]
  static debounces = ["runSearch"]
  static values = {
    candidatesUrl: String,
    fieldName: String,
    frameId: { type: String, default: "person-picker-candidates" }
  }

  connect() {
    super.connect()
    // Shared debounce primitive (house rule) — also cancels a pending search
    // on disconnect, so a Turbo navigation inside the wait window can't fire
    // against a detached frame.
    useDebounce(this, { wait: 250 })
  }

  // Repoint the results frame at the query (debounced — see static debounces).
  search() {
    this.runSearch()
  }

  runSearch() {
    const results = this.resultsFrame()
    if (!results) return
    const q = (this.searchTarget.value || "").trim()
    const url = new URL(this.candidatesUrlValue, window.location.origin)
    url.searchParams.set("q", q)
    results.src = url.toString()
  }

  // Add a candidate to the selection (idempotent on person id).
  add(event) {
    const { personId, name } = event.params || {}
    if (!personId || this.selectedIds().includes(personId)) return

    this.idsTarget.appendChild(this.hiddenInput(personId))
    this.selectedTarget.appendChild(this.chip(personId, name))
    if (this.hasEmptyTarget) this.emptyTarget.classList.add("hidden")
    this.toggleSuggestion(personId, false)
    this.selectionChanged()
  }

  // Remove a chip + its hidden input; restore its suggestion if any.
  remove(event) {
    const id = event.params?.personId
    if (!id) return
    this.element.querySelectorAll(`input[data-person-id="${id}"], span[data-person-id="${id}"]`)
      .forEach((el) => el.remove())
    this.toggleSuggestion(id, true)
    if (this.hasEmptyTarget && this.selectedIds().length === 0) this.emptyTarget.classList.remove("hidden")
    this.selectionChanged()
  }

  // protected — subclass extension points

  // Hook invoked after every add/remove (e.g. to refresh a submit label).
  selectionChanged() {}

  // The hidden-input name the selection submits under.
  fieldName() {
    return this.fieldNameValue
  }

  resultsFrame() {
    return this.hasResultsTarget
      ? this.resultsTarget
      : this.element.querySelector(`turbo-frame#${this.frameIdValue}`)
  }

  selectedIds() {
    return Array.from(this.idsTarget.querySelectorAll("input")).map((i) => i.value)
  }

  // Build the hidden id input + the removable chip via DOM methods (textContent
  // escapes automatically) — never string-interpolate person data into HTML.
  hiddenInput(personId) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = this.fieldName()
    input.value = personId
    input.dataset.personId = personId
    return input
  }

  chip(personId, name) {
    const chip = document.createElement("span")
    chip.className = "inline-flex items-center gap-1 min-h-9 px-2.5 rounded-full bg-neutral-subtle text-default text-xs font-medium"
    chip.dataset.personId = personId
    chip.append(name || "")

    const remove = document.createElement("button")
    remove.type = "button"
    remove.setAttribute("aria-label", `Remove ${name || "person"}`)
    remove.className = "leading-none rounded-full text-muted hover:text-default hover:bg-neutral-muted cursor-pointer"
    remove.dataset.action = `${this.identifier}#remove`
    remove.dataset[`${this.paramPrefix}PersonIdParam`] = personId
    remove.textContent = "×"
    chip.appendChild(remove)
    return chip
  }

  // Hide (show=false) or restore (show=true) a person's suggestion chip. Use an
  // inline display style, not a `hidden` class: the chip already carries an
  // `inline-flex` display utility, and Tailwind's `hidden` ties it on specificity
  // (source order wins, so the class wouldn't reliably hide it). Inline style does.
  toggleSuggestion(personId, show) {
    if (!this.hasSuggestionsTarget) return
    this.suggestionsTarget
      .querySelectorAll(`[data-${this.identifier}-person-id-param="${personId}"]`)
      .forEach((el) => { el.style.display = show ? "" : "none" })
  }

  // "person-picker" → "personPicker" (dataset camelCase key prefix).
  get paramPrefix() {
    return this.identifier.replace(/-([a-z])/g, (_, c) => c.toUpperCase())
  }
}

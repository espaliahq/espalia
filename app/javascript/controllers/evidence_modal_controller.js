// Drives the unified evidence modal. Replaces evidence_form, evidence_edit_form,
// evidence_link_form, and evidence_response.
//
// Two roles, same controller class:
//   - PAGE instance (on the wrapper with `modal`): `load` sets the lazy
//     turbo-frame `src` from a trigger's action params, so the server renders
//     the right mode/prefill each open.
//   - IN-FRAME instance (inside the rendered form): `typeChanged` toggles the
//     custom-type label; `addLink`/`removeLink` manage the "also applies to"
//     rows, each showing that cell's behavioural expectation (read from an
//     embedded JSON map).
//
// Usage (page trigger):
//   <button data-action="evidence-modal#load modal#open"
//           data-evidence-modal-mode-param="new"
//           data-evidence-modal-assignment-id-param="…"
//           data-evidence-modal-capability-stable-id-param="…"
//           data-evidence-modal-level-ordinal-param="3"
//           data-evidence-modal-return-to-param="assessment:…">+ Add evidence</button>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["frame", "typeSelect", "customLabel", "linkRows", "linkCapability", "linkLevel", "expectations"]
  static values = { url: { type: String, default: "/evidence_modal" } }

  // PAGE: point the lazy frame at the render endpoint for this trigger.
  load(event) {
    if (!this.hasFrameTarget) return
    const p = event.params || {}
    const q = new URLSearchParams()
    if (p.mode) q.set("mode", p.mode)
    if (p.evidenceId) q.set("evidence_id", p.evidenceId)
    if (p.requestId) q.set("request_id", p.requestId)
    if (p.assignmentId) q.set("assignment_id", p.assignmentId)
    if (p.capabilityStableId) q.set("capability_stable_id", p.capabilityStableId)
    if (p.levelOrdinal != null && p.levelOrdinal !== "") q.set("level_ordinal", p.levelOrdinal)
    if (p.returnTo) q.set("return_to", p.returnTo)
    this.frameTarget.src = `${this.urlValue}?${q.toString()}`
  }

  // IN-FRAME: reveal the custom-type label only for "other".
  typeChanged() {
    if (!this.hasTypeSelectTarget || !this.hasCustomLabelTarget) return
    this.customLabelTarget.classList.toggle("hidden", this.typeSelectTarget.value !== "other")
  }

  // IN-FRAME: add an "also applies to" cell as a row with its expectation.
  addLink() {
    if (!this.hasLinkRowsTarget || !this.hasLinkCapabilityTarget || !this.hasLinkLevelTarget) return
    const cap = this.linkCapabilityTarget.value
    const level = this.linkLevelTarget.value
    if (!cap || !level) return

    const token = `${cap}|${level}`
    if (this.element.querySelector(`input[name="evidence[desired_links][]"][value="${token}"]`)) return // dup or primary
    const info = this.#expectations()[token]
    if (!info) return // not a valid cell

    this.linkRowsTarget.appendChild(this.#row(token, level, info))
    this.linkCapabilityTarget.value = ""
    this.linkLevelTarget.value = ""
  }

  removeLink(event) {
    event.target.closest("[data-link-row]")?.remove()
  }

  // private

  #row(token, level, info) {
    const row = document.createElement("div")
    row.dataset.linkRow = ""
    row.className = "rounded-md border border-gray-200 dark:border-gray-700 p-2 text-sm"

    const head = document.createElement("div")
    head.className = "flex items-start justify-between gap-2"
    const title = document.createElement("span")
    title.className = "font-medium text-gray-900 dark:text-white"
    title.textContent = `${info.capability_name} · L${level}`
    const remove = document.createElement("button")
    remove.type = "button"
    remove.dataset.action = "evidence-modal#removeLink"
    remove.className = "text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 cursor-pointer"
    remove.setAttribute("aria-label", "Remove link")
    remove.textContent = "×"
    head.append(title, remove)
    row.appendChild(head)

    if (info.expectation) {
      const exp = document.createElement("p")
      exp.className = "mt-0.5 text-xs text-gray-600 dark:text-gray-300"
      exp.textContent = `↳ ${info.expectation}`
      row.appendChild(exp)
    }

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = "evidence[desired_links][]"
    hidden.value = token
    row.appendChild(hidden)
    return row
  }

  #expectations() {
    if (!this.hasExpectationsTarget) return {}
    try {
      return JSON.parse(this.expectationsTarget.textContent)
    } catch {
      return {}
    }
  }
}

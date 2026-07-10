// Drives the unified evidence modal. Replaces evidence_form, evidence_edit_form,
// evidence_link_form, and evidence_response.
//
// Two roles, same controller class:
//   - PAGE instance (on the wrapper with `modal`): `load` sets the lazy
//     turbo-frame `src` from a trigger's action params, so the server renders
//     the right mode/prefill each open.
//   - IN-FRAME instance (inside the rendered form): `typeChanged` toggles the
//     custom-type label; `addLink`/`removeLink` manage the "Applies to"
//     rows, each showing that cell's behavioural expectation and expandable
//     examples (read from an embedded JSON map). Remove buttons lock when
//     only one row remains — feedback must apply somewhere.
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
  static targets = ["frame", "typeSelect", "customLabel", "linkRows", "linkCapability", "linkLevel", "expectations", "levels", "valences"]
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

  // IN-FRAME: rebuild the level dropdown for the chosen capability — only its
  // valid cells (those with an expectation), with already-linked levels
  // (including the primary) disabled.
  capabilityChanged() {
    this.#rebuildLevels()
  }

  // IN-FRAME: add an "Applies to" cell as a row with its expectation and
  // examples. The staged row carries a REQUIRED valence select, so a new
  // link can't be submitted without one — but staging the row itself stays
  // a plain capability + level pick.
  addLink() {
    if (!this.hasLinkRowsTarget || !this.hasLinkCapabilityTarget || !this.hasLinkLevelTarget) return
    const cap = this.linkCapabilityTarget.value
    const level = this.linkLevelTarget.value
    if (!cap || !level) return

    const token = `${cap}|${level}`
    if (this.#isLinked(cap, level)) return // dup (also disabled in the UI)
    const info = this.#expectations()[token]
    if (!info) return // not a valid cell

    this.linkRowsTarget.appendChild(this.#row(token, level, info))
    this.linkLevelTarget.value = ""
    this.#rebuildLevels() // the just-added level is now disabled; keep the capability selected
    this.#updateRemoveButtons()
  }

  removeLink(event) {
    event.target.closest("[data-link-row]")?.remove()
    this.#rebuildLevels() // the freed level becomes selectable again
    this.#updateRemoveButtons()
  }

  // private

  #rebuildLevels() {
    if (!this.hasLinkLevelTarget || !this.hasLinkCapabilityTarget) return
    const sel = this.linkLevelTarget
    sel.replaceChildren(new Option("Level…", ""))

    const cap = this.linkCapabilityTarget.value
    if (!cap) return

    const labels = this.#levelLabels()
    const levels = Object.keys(this.#expectations())
      .filter((key) => key.startsWith(`${cap}|`))
      .map((key) => parseInt(key.split("|")[1], 10))
      .sort((a, b) => a - b)

    levels.forEach((level) => {
      const linked = this.#isLinked(cap, level)
      const opt = new Option(`${labels[level] || `L${level}`}${linked ? " (linked)" : ""}`, String(level))
      opt.disabled = linked
      sel.add(opt)
    })
  }

  #isLinked(cap, level) {
    return !!this.element.querySelector(`input[name="evidence[desired_links][]"][value="${cap}|${level}"]`)
  }

  #levelLabels() {
    if (!this.hasLevelsTarget) return {}
    try {
      return Object.fromEntries(JSON.parse(this.levelsTarget.textContent).map((l) => [l.ordinal, l.label]))
    } catch {
      return {}
    }
  }

  #row(token, level, info) {
    const row = document.createElement("div")
    row.dataset.linkRow = ""
    row.className = "rounded-md border border-gray-200 dark:border-gray-700 p-2 text-sm space-y-1"

    const head = document.createElement("div")
    head.className = "flex items-start justify-between gap-2"
    const title = document.createElement("span")
    title.className = "font-medium text-gray-900 dark:text-white"
    title.textContent = `${info.capability_name} · ${this.#levelLabels()[level] || `L${level}`}`
    const remove = document.createElement("button")
    remove.type = "button"
    remove.dataset.action = "evidence-modal#removeLink"
    remove.className = "text-gray-400 hover:text-gray-700 dark:hover:text-gray-200 cursor-pointer " +
      "disabled:opacity-40 disabled:cursor-not-allowed"
    remove.setAttribute("aria-label", "Remove link")
    remove.textContent = "×"
    head.append(title, remove)
    row.appendChild(head)

    if (info.expectation) {
      const exp = document.createElement("p")
      exp.className = "text-xs text-gray-600 dark:text-gray-300"
      exp.textContent = `↳ ${info.expectation}`
      row.appendChild(exp)
    }

    row.appendChild(this.#valenceSelect(token))
    if (info.illustrations?.length) row.appendChild(this.#examples(info.illustrations))

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = "evidence[desired_links][]"
    hidden.value = token
    row.appendChild(hidden)
    return row
  }

  // Collapsible examples list, mirroring the server-rendered rows' <details>.
  #examples(list) {
    const details = document.createElement("details")
    details.className = "group"
    const summary = document.createElement("summary")
    summary.className = "cursor-pointer select-none text-xs font-semibold uppercase tracking-wide " +
      "text-gray-600 dark:text-gray-300 marker:content-none flex items-center gap-1"
    const chevron = document.createElement("span")
    chevron.className = "transition-transform group-open:rotate-90"
    chevron.setAttribute("aria-hidden", "true")
    chevron.textContent = "▸"
    const label = document.createElement("span")
    label.textContent = `Examples (${list.length})`
    summary.append(chevron, label)
    details.appendChild(summary)

    const ul = document.createElement("ul")
    ul.className = "mt-1 space-y-1"
    list.forEach((text) => {
      const li = document.createElement("li")
      li.className = "flex gap-2 text-xs text-gray-700 dark:text-gray-200"
      const bullet = document.createElement("span")
      bullet.className = "text-gray-400"
      bullet.setAttribute("aria-hidden", "true")
      bullet.textContent = "•"
      const body = document.createElement("span")
      body.textContent = text
      li.append(bullet, body)
      ul.appendChild(li)
    })
    details.appendChild(ul)
    return details
  }

  // An item must keep at least one link: when a single row remains, its
  // remove button (if it has one — the :new/:respond seed row doesn't)
  // locks. Re-enables as soon as a second row is staged.
  #updateRemoveButtons() {
    if (!this.hasLinkRowsTarget) return
    const rows = this.linkRowsTarget.querySelectorAll("[data-link-row]")
    const lock = rows.length === 1
    rows.forEach((row) => {
      const button = row.querySelector("button[data-action*='removeLink']")
      if (!button) return
      button.disabled = lock
      if (lock) {
        button.title = "Feedback must apply to at least one behaviour — withdraw it instead"
      } else {
        button.removeAttribute("title")
      }
    })
  }

  // A NEW link's valence is mandatory: the staged row's select is required
  // with a blank placeholder, so the form can't submit until it's chosen.
  // Options come from the embedded JSON so labels stay server-owned.
  #valenceSelect(token) {
    const select = document.createElement("select")
    select.name = `evidence[link_valences][${token}]`
    select.required = true
    select.setAttribute("aria-label", "Evidence valence")
    select.className = "w-full rounded-md border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 " +
      "text-gray-900 dark:text-gray-100 text-xs focus-visible:ring-primary focus-visible:border-primary"
    select.add(new Option("Valence…", ""))
    this.#valenceOptions().forEach(([label, value]) => select.add(new Option(label, value)))
    return select
  }

  #valenceOptions() {
    if (!this.hasValencesTarget) return []
    try {
      return JSON.parse(this.valencesTarget.textContent)
    } catch {
      return []
    }
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

// ONE inline editor for the whole Framework Explorer.
//
// Every editable text used to ship its own hidden <form> + <textarea> +
// Stimulus mount — 374 of each in the seeded me&u edit matrix, a third of the
// frame's bytes. Now the display markup carries DATA only and this controller,
// mounted once on the explorer root, clones a <template> into place when a
// pencil is clicked. Event delegation via Stimulus actions means editors
// inserted late (the on-demand expanded row) work with no extra wiring.
//
// Host contract — any element carrying `data-editor-action`:
//
//   data-editor-action        POST/PATCH URL (required)
//   data-editor-method        "patch" (default) or "post"
//   data-editor-field         name= for the textarea ("capability[name]")
//   data-editor-value         value to seed (the pending proposal when one exists)
//   data-editor-rows          initial textarea rows (default 3)
//   data-editor-label         accessible name for the textarea
//   data-editor-placeholder   textarea placeholder
//   data-editor-entity        suggestion entity type — drives Save vs Propose
//   data-editor-outcome       "apply" | "propose" — fixed override of the above
//   data-editor-submit-label  overrides the derived Save/Propose label
//   data-editor-turbo-frame   data-turbo-frame for the form ("_top")
//   data-editor-form-class    extra classes for the form element
//   data-editor-extra         JSON {name: value} of hidden inputs
//   data-editor-error         server-rendered save error — the editor re-opens
//                             on it automatically, seeded with the attempted
//                             value, so typed text is never lost
//
// Inside the host, `[data-editor-display]` is the read-mode element (hidden
// while editing) and a pencil carries `data-action="field-editor#open"`.
//
// Save vs Propose is honest, not decorative: the root publishes the viewer's
// server-computed per-entity approval authority (`approvalsValue`) and the
// current Editing/Suggesting mode; a save only applies when BOTH hold.

import BaseController from "controllers/base_controller"

const CONNECTION_ERROR = "Couldn't save — check your connection and try again."
const REJECTED_ERROR = "Couldn't save — the page may be out of date. Reload and try again."
const DISCARD_PROMPT = "Discard your unsaved change?"

export default class extends BaseController {
  static targets = ["template"]
  static values = {
    // { "capability": true, "behavioural_expectation": false, … } — whether the
    // viewer clears each entity's review tier. Computed server-side from
    // Frameworks::SuggestionApprovalAuthority; never guessed on the client.
    approvals: { type: Object, default: {} },
    mode: { type: String, default: "editing" }
  }

  connect() {
    super.connect()
    this.openHost = null
    this.openForm = null
  }

  disconnect() {
    this.#discardEditor()
    super.disconnect()
  }

  // ── Opening / closing ──

  // Pencil click. Stops propagation so opening an editor never also toggles
  // the matrix row / focuses the cell underneath it.
  open(event) {
    event.preventDefault()
    event.stopPropagation()

    const host = event.currentTarget.closest("[data-editor-action]")
    if (!host) return
    if (host === this.openHost) {
      this.#input()?.focus()
      return
    }
    if (!this.#closeOpenEditor()) return

    this.#openOn(host)
  }

  cancel() {
    this.#closeOpenEditor({ force: true })
  }

  keydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.cancel()
      return
    }
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      this.openForm?.requestSubmit()
    }
  }

  // Grow the textarea with its content (and mark the editor dirty) so a long
  // expectation isn't edited through a 3-row porthole.
  autogrow() {
    const input = this.#input()
    if (!input) return
    input.style.height = "auto"
    input.style.height = `${input.scrollHeight}px`
    this.#refreshDirty()
  }

  // ── Submission outcomes ──

  submitted(event) {
    if (event.detail?.success) {
      // The frame swap already removed our form; just drop the reference and
      // let the context pane know a suggestion may have landed.
      this.#forgetEditor()
      window.dispatchEvent(new CustomEvent("suggestion:submitted", {
        bubbles: true,
        detail: { formAction: event.target.action }
      }))
      return
    }

    // A domain rejection re-renders the entity's frame with data-editor-error
    // + the attempted value. That render is async and NOT awaited before
    // turbo:submit-end fires, so the re-open is driven by turbo:frame-render
    // (#frameRendered) — here we only drop the now-detached form.
    this.#forgetEditor()
  }

  // The entity's frame was replaced. When the new content carries a save error,
  // re-open the editor on it, seeded with the value the user tried to save.
  frameRendered(event) {
    const host = event.target?.querySelector?.("[data-editor-error]")
    if (!host || host === this.openHost) return

    this.#closeOpenEditor({ force: true })
    this.#openOn(host)
  }

  // The response had no matching frame (a 5xx page, a sign-in redirect). Turbo
  // would render its own "Content missing" into the cell and take the editor
  // with it — claim the event, keep the editor and its text, and say so.
  frameMissing(event) {
    if (!this.#eventTouchesOpenEditor(event)) return

    event.preventDefault()
    this.#showTransportError(REJECTED_ERROR)
  }

  // The network dropped mid-submit — nothing rendered at all.
  fetchError(event) {
    if (!this.#eventTouchesOpenEditor(event)) return

    this.#showTransportError(CONNECTION_ERROR)
  }

  // ── Editing / Suggesting toggle ──

  modeChanged(event) {
    const mode = event.detail?.mode
    if (mode !== "editing" && mode !== "suggesting") return

    this.modeValue = mode
    if (this.openHost) this.#applyOutcome(this.openHost)
  }

  // Whether an editor is open with unsaved text — the guard `matrix#refresh`
  // and the filter axes consult before re-fetching the matrix out from under it.
  get dirty() {
    return this.element.dataset.editorDirty === "true"
  }

  // private

  #openOn(host) {
    const form = this.#buildForm(host)
    if (!form) return

    const display = host.querySelector("[data-editor-display]")
    // Inline style, not a `hidden` class: the display element usually carries
    // its own `flex`/`inline-flex` utility, which ties `.hidden` on
    // specificity and wins on source order (assessments.md Lesson 17).
    if (display) display.style.display = "none"
    host.appendChild(form)

    this.openHost = host
    this.openForm = form
    this.initialValue = this.#input()?.value ?? ""
    this.#refreshDirty()

    const input = this.#input()
    if (input) {
      input.focus()
      try {
        input.setSelectionRange(input.value.length, input.value.length)
      } catch { /* non-text input — ignore */ }
      this.autogrow()
    }
  }

  #buildForm(host) {
    if (!this.hasTemplateTarget) return null

    const form = this.templateTarget.content.firstElementChild.cloneNode(true)
    const data = host.dataset

    form.setAttribute("action", data.editorAction)
    if (data.editorTurboFrame) form.setAttribute("data-turbo-frame", data.editorTurboFrame)
    if (data.editorFormClass) form.className = `${form.className} ${data.editorFormClass}`
    // A host can ask for one more Stimulus controller on the form (the
    // department rename needs `tree-scope-fields` to carry the role selection).
    if (data.editorFormController) form.setAttribute("data-controller", data.editorFormController)

    const methodField = form.querySelector("[data-editor-method-field]")
    if ((data.editorMethod || "patch") === "post") {
      methodField?.remove()
    } else if (methodField) {
      methodField.value = data.editorMethod || "patch"
    }

    this.#appendExtraFields(form, data.editorExtra)

    const input = form.querySelector("[data-editor-input]")
    input.name = data.editorField
    input.value = data.editorValue || ""
    input.rows = Number(data.editorRows || 3)
    if (data.editorPlaceholder) input.placeholder = data.editorPlaceholder
    if (data.editorLabel) input.setAttribute("aria-label", data.editorLabel)

    this.#applyOutcome(host, form)
    return form
  }

  #appendExtraFields(form, json) {
    if (!json) return

    let fields
    try {
      fields = JSON.parse(json)
    } catch {
      return
    }
    Object.entries(fields).forEach(([name, value]) => {
      const field = document.createElement("input")
      field.type = "hidden"
      field.name = name
      field.value = value == null ? "" : String(value)
      form.appendChild(field)
    })
  }

  // The Save button says what will actually happen, and a proposal tints the
  // editor amber — the explorer's pending-change colour.
  #applyOutcome(host, form = this.openForm) {
    if (!form) return

    const propose = this.#outcomeFor(host) === "propose"
    const submit = form.querySelector("[data-editor-submit]")
    if (submit) {
      submit.textContent = host.dataset.editorSubmitLabel || (propose ? "Propose" : "Save")
    }
    const hint = form.querySelector("[data-editor-hint]")
    if (hint) {
      hint.textContent = propose ? "Lands as a suggestion for review" : "Applies immediately"
    }
    const input = form.querySelector("[data-editor-input]")
    if (input) {
      input.classList.toggle("border-amber-400", propose)
      input.classList.toggle("border-primary", !propose)
    }
  }

  #outcomeFor(host) {
    const fixed = host.dataset.editorOutcome
    if (fixed === "apply" || fixed === "propose") return fixed

    const entity = host.dataset.editorEntity
    if (!entity) return "apply"
    if (this.modeValue === "suggesting") return "propose"
    return this.approvalsValue[entity] ? "apply" : "propose"
  }

  // Returns false when the user declined to discard unsaved text.
  #closeOpenEditor({ force = false } = {}) {
    if (!this.openForm) return true
    if (!force && this.dirty && !window.confirm(DISCARD_PROMPT)) {
      this.#input()?.focus()
      return false
    }
    const host = this.openHost
    this.#discardEditor()
    host?.querySelector("[data-action*='field-editor#open']")?.focus()
    return true
  }

  #discardEditor() {
    this.openForm?.remove()
    this.#forgetEditor()
  }

  #forgetEditor() {
    const display = this.openHost?.querySelector("[data-editor-display]")
    if (display) display.style.display = ""
    this.openHost = null
    this.openForm = null
    this.initialValue = ""
    delete this.element.dataset.editorDirty
  }

  #refreshDirty() {
    const changed = (this.#input()?.value ?? "") !== this.initialValue
    this.element.dataset.editorDirty = changed ? "true" : "false"
  }

  #input() {
    return this.openForm?.querySelector("[data-editor-input]")
  }

  #eventTouchesOpenEditor(event) {
    return Boolean(this.openForm?.isConnected && event.target?.contains?.(this.openForm))
  }

  #showTransportError(message) {
    const box = this.openForm?.querySelector("[data-editor-error-live]")
    if (!box) return

    box.textContent = message
    box.hidden = false
  }
}

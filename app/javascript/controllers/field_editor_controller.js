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
// `scrollHeight` excludes the border, and `box-sizing: border-box` then clips
// the last line by exactly that much — hence the +2px on autogrow.
const BORDER_ALLOWANCE = 2

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
    this.submittingForm = null
    this.#clearDirty()
    // A Turbo Drive cache snapshot is taken BEFORE disconnect() runs, so a
    // restored page can carry an orphaned editor whose display element is still
    // hidden. Clear any before the user meets it.
    this.element.querySelectorAll("[data-editor-form]").forEach((form) => {
      const display = form.parentElement?.querySelector("[data-editor-display]")
      if (display) display.style.display = ""
      form.remove()
    })
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

  // The matrix is about to re-fetch and the user accepted the discard prompt —
  // let go of the editor so its dirty flag doesn't outlive the frame swap and
  // re-prompt on every later filter change (or on a programmatic
  // `matrix#refresh`, which has no user gesture behind it at all).
  discard() {
    this.#closeOpenEditor({ force: true })
  }

  keydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.cancel()
      return
    }
    // Cmd/Ctrl+Enter always saves. On a single-row host (a level title, a
    // category name, a department label) plain Enter saves too — a newline
    // there is never wanted, and it used to be an <input type=text>.
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey || this.#singleRow)) {
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
    input.style.height = `${input.scrollHeight + BORDER_ALLOWANCE}px`
    this.#refreshDirty()
  }

  // ── Submission outcomes ──

  // Arms the transport-failure handlers for THIS editor's own submission. The
  // flag outlives turbo:submit-end on purpose: `frameMissing` is dispatched from
  // inside an un-awaited `loadResponse`, so it can land afterwards (verified in
  // turbo-rails 2.0.23) — the events that consume it clear it.
  submitStart(event) {
    if (event.target !== this.openForm) return

    this.submittingForm = event.target
  }

  submitted(event) {
    if (event.detail?.success) {
      // The frame swap will remove this form; drop the reference and let the
      // context pane know a suggestion may have landed.
      this.submittingForm = null
      this.#forgetEditor()
      window.dispatchEvent(new CustomEvent("suggestion:submitted", {
        bubbles: true,
        detail: { formAction: event.target.action }
      }))
      return
    }

    // Deliberately keep owning the editor on failure. The response's frame
    // render — and any turbo:frame-missing — happen in an un-awaited
    // `loadResponse` that can resolve AFTER submit-end, so dropping the
    // reference here would disarm `frameMissing` and strand the form on a
    // network error (it would still be on screen, but Cancel would no-op).
  }

  // The entity's frame was replaced. When the new content carries a save error,
  // re-open the editor on it, seeded with the value the user tried to save.
  frameRendered(event) {
    if (this.submittingForm && event.target?.contains?.(this.submittingForm)) {
      this.submittingForm = null
    }
    const host = event.target?.querySelector?.("[data-editor-error]")
    if (!host) {
      // Our host went with the render (a successful save, or a rejection that
      // rendered no error) — stop tracking the now-detached form.
      if (this.openHost && !this.openHost.isConnected) this.#forgetEditor()
      return
    }
    if (host === this.openHost) return

    this.#closeOpenEditor({ force: true })
    this.#openOn(host)
  }

  // The response had no matching frame (a 5xx page, a sign-in redirect). Turbo
  // would render its own "Content missing" into the cell and take the editor
  // with it — claim the event, keep the editor and its text, and say so.
  frameMissing(event) {
    if (!this.#ownSubmissionFrame(event)) return

    this.submittingForm = null
    event.preventDefault()
    this.#showTransportError(REJECTED_ERROR)
  }

  // The network dropped mid-submit — nothing rendered at all.
  fetchError(event) {
    // The event's target is the FORM for a submission and the FRAME for a frame
    // load, so this identity check keeps us out of the matrix / expanded-row
    // frames' own failure handling.
    if (!this.submittingForm || event.target !== this.submittingForm) return

    this.submittingForm = null
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

    this.#pinWidth(host, form)
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

  // `width: 100%` is unreliable inside an auto-layout table: the cell's width
  // isn't settled during the intrinsic pass, so the percentage falls back to
  // shrink-to-fit and the editor collapses to roughly its buttons (~110px).
  // Pin it to the host's OWN pre-open width instead — the host already occupies
  // exactly that, so the column's negotiation is unchanged whatever the
  // viewport. Never floor it to a "comfortable" minimum: on a squeezed mobile
  // table that floor becomes new min-content and widens the column (Lesson 27).
  // Hosts that want a roomy editor make themselves full-width instead (a
  // percentage width contributes nothing intrinsic) — see LevelTitleFrame.
  #pinWidth(host, form) {
    const hostWidth = host.getBoundingClientRect().width
    let cellInner = Infinity
    const cell = host.closest("td, th")
    if (cell) {
      const style = window.getComputedStyle(cell)
      cellInner =
        cell.clientWidth - parseFloat(style.paddingLeft || 0) - parseFloat(style.paddingRight || 0)
    }
    const width = Math.min(hostWidth, cellInner)
    if (width > 0) form.style.width = `${width}px`
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
    // A rejected save re-rendered the frame with a server-side alert. Abandoning
    // the edit must take the alert with it, or the cell keeps a
    // permanent-looking "Couldn't save" banner until the next frame render.
    this.openHost?.querySelector("[data-editor-error-line]")?.remove()
    this.openHost?.removeAttribute("data-editor-error")
    this.#forgetEditor()
  }

  #forgetEditor() {
    const display = this.openHost?.querySelector("[data-editor-display]")
    if (display) display.style.display = ""
    this.openHost = null
    this.openForm = null
    this.initialValue = ""
    this.#clearDirty()
  }

  #clearDirty() {
    delete this.element.dataset.editorDirty
  }

  #refreshDirty() {
    const changed = (this.#input()?.value ?? "") !== this.initialValue
    this.element.dataset.editorDirty = changed ? "true" : "false"
  }

  #input() {
    return this.openForm?.querySelector("[data-editor-input]")
  }

  get #singleRow() {
    return this.openHost?.dataset.editorRows === "1"
  }

  // turbo:frame-missing is dispatched on the FRAME unconditionally, including
  // for frame loads this controller knows nothing about — claim it only while
  // our own submission is in flight and only for the frame that submission
  // targeted.
  #ownSubmissionFrame(event) {
    return Boolean(
      this.submittingForm?.isConnected &&
      event.target === this.submittingForm.closest("turbo-frame")
    )
  }

  #showTransportError(message) {
    const box = this.openForm?.querySelector("[data-editor-error-live]")
    if (!box) return

    box.textContent = message
    box.hidden = false
  }
}

// Prefills the shared "Discuss…" modal from a trigger in the matrix (an
// expectation cell, a capability row kebab, or an illustration kebab) and, on
// success, opens the new discussion's card in the context pane.
//
// On the window `modal:open` event it self-gates on a `discuss*` dataset key,
// copies the anchor into the form's hidden fields, shows where in the framework
// the question lands, and — when the trigger has no single cell in mind (the
// capability row) — populates a level select. On a successful submit it reads
// the new suggestion id from the `X-Suggestion-Id` response header and
// dispatches `suggestion:open-card`; the modal closes itself (modal#submitted)
// and the feed reloads via the activity broadcast.
//
// Usage:
//   <form data-controller="request-clarification-form"
//         data-action="turbo:submit-end->modal#submitted
//                      turbo:submit-end->request-clarification-form#submitted">
//     <input    data-request-clarification-form-target="capabilityId">
//     <input    data-request-clarification-form-target="illustrationId">
//     <p        data-request-clarification-form-target="context"></p>
//     <div      data-request-clarification-form-target="levelField">
//       <select data-request-clarification-form-target="levelSelect"></select>
//     </div>
//     <textarea data-request-clarification-form-target="question"></textarea>
//   </form>
//
// Trigger dataset:
//   data-discuss-capability-id     the capability (cell + row triggers)
//   data-discuss-illustration-id   the illustration (illustration trigger)
//   data-discuss-level-ordinal     the level, when the trigger names one cell
//   data-discuss-context-label     e.g. "Strategic Thinking · L5"
//   data-discuss-level-options     JSON [{ordinal, label}] → shows the select

import { Controller } from "@hotwired/stimulus"

const SUGGESTION_ID_HEADER = "X-Suggestion-Id"
const WHOLE_CAPABILITY_LABEL = "The capability as a whole"

export default class extends Controller {
  static targets = ["capabilityId", "illustrationId", "context", "levelField", "levelSelect", "question"]

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  submitted(event) {
    if (!event.detail?.success) return

    const suggestionId = event.detail.fetchResponse?.header(SUGGESTION_ID_HEADER)
    if (suggestionId) {
      window.dispatchEvent(new CustomEvent("suggestion:open-card", { detail: { suggestionId } }))
    } else {
      // No id to open a card with — at least surface the new entry in the feed.
      window.dispatchEvent(new CustomEvent("suggestion:submitted", { detail: {} }))
    }
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to Discuss triggers (other modals share the modal:open bus).
    if (data.discussCapabilityId === undefined && data.discussIllustrationId === undefined) return

    if (this.hasCapabilityIdTarget) this.capabilityIdTarget.value = data.discussCapabilityId || ""
    if (this.hasIllustrationIdTarget) this.illustrationIdTarget.value = data.discussIllustrationId || ""
    if (this.hasQuestionTarget) this.questionTarget.value = ""

    this.#fillContext(data.discussContextLabel)
    this.#fillLevels(data.discussLevelOptions, data.discussLevelOrdinal)
  }

  #fillContext(label) {
    if (!this.hasContextTarget) return

    this.contextTarget.textContent = label || ""
    this.contextTarget.classList.toggle("hidden", !label)
  }

  // A trigger that names one cell submits its ordinal as a plain value; a
  // capability-level trigger offers the choice (including "no level", which
  // anchors the discussion on the capability as a whole).
  #fillLevels(optionsJson, ordinal) {
    if (!this.hasLevelFieldTarget || !this.hasLevelSelectTarget) return

    const options = this.#parseOptions(optionsJson)
    this.levelSelectTarget.innerHTML = ""

    if (options.length === 0) {
      this.levelFieldTarget.classList.add("hidden")
      this.levelSelectTarget.appendChild(new Option("", ordinal || "", true, true))
      return
    }

    this.levelFieldTarget.classList.remove("hidden")
    this.levelSelectTarget.appendChild(new Option(WHOLE_CAPABILITY_LABEL, ""))
    options.forEach(({ ordinal: value, label }) => {
      this.levelSelectTarget.appendChild(new Option(label, value))
    })
    this.levelSelectTarget.value = ordinal || ""
  }

  #parseOptions(json) {
    if (!json) return []

    try {
      const parsed = JSON.parse(json)
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }
}

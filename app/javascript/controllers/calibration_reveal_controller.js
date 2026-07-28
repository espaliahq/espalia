// Reveal-on-interrogation choreography for the calibration drill-in.
//
// Anonymization here is conversation choreography, not privacy control
// (docs/architecture/calibration-sessions.md): every dot renders with a
// generic accessible name; opening a dot's person card (?person=) IS the
// reveal gesture, sticky per person for the session via sessionStorage.
// A "Show names" toggle reveals everything for high-trust rooms.
//
// Example usage:
// <div data-controller="calibration-reveal"
//      data-calibration-reveal-session-id-value="<uuid>"
//      data-calibration-reveal-reveal-person-value="<uuid or ''>">
//   <a data-calibration-reveal-target="dot"
//      data-person-id="..." data-person-name="..." data-base-label="...">…</a>
//   <button data-calibration-reveal-target="toggle"
//           data-action="calibration-reveal#toggleNamed">Show names</button>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["dot", "toggle"]
  static values = {
    sessionId: String,
    revealPerson: { type: String, default: "" }
  }

  connect() {
    super.connect()
    this.state = this.loadState()
    if (this.revealPersonValue) {
      this.state.ids = Array.from(new Set([...this.state.ids, this.revealPersonValue]))
      this.saveState()
    }
    this.apply()
  }

  toggleNamed() {
    this.state.named = !this.state.named
    this.saveState()
    this.apply()
  }

  // private

  apply() {
    const revealed = new Set(this.state.ids)
    this.dotTargets.forEach((dot) => {
      const isRevealed = this.state.named || revealed.has(dot.dataset.personId)
      if (isRevealed) {
        dot.title = dot.dataset.personName
        dot.setAttribute("aria-label", `${dot.dataset.personName} — ${dot.dataset.baseLabel}. Open to discuss.`)
        dot.dataset.revealed = "true"
      } else {
        dot.removeAttribute("title")
        dot.setAttribute("aria-label", `Population member — ${dot.dataset.baseLabel}. Open to discuss.`)
        dot.dataset.revealed = "false"
      }
    })
    if (this.hasToggleTarget) {
      this.toggleTarget.textContent = this.state.named ? "Hide names" : "Show names"
      this.toggleTarget.setAttribute("aria-pressed", String(this.state.named))
    }
  }

  loadState() {
    try {
      const raw = sessionStorage.getItem(this.storageKey)
      const parsed = raw ? JSON.parse(raw) : {}
      return { named: Boolean(parsed.named), ids: Array.isArray(parsed.ids) ? parsed.ids : [] }
    } catch {
      return { named: false, ids: [] }
    }
  }

  saveState() {
    try {
      sessionStorage.setItem(this.storageKey, JSON.stringify(this.state))
    } catch {
      // sessionStorage unavailable (private mode etc.) — reveal stays per-page.
    }
  }

  get storageKey() {
    return `calibration-reveal-${this.sessionIdValue}`
  }
}

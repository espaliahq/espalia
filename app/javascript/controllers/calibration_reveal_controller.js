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
//      data-calibration-reveal-reveal-person-value="<uuid or ''>"
//      data-calibration-reveal-reveal-persons-value='["<uuid>", …]'>
//   <a data-calibration-reveal-target="dot"
//      data-person-id="..." data-person-name="..." data-base-label="...">…</a>
//   <li data-calibration-reveal-target="wallItem" data-person-id="...">
//     <div data-reveal-role="summary">…shape only…</div>
//     <div data-reveal-role="detail" class="hidden">…name + text…</div>
//   </li>
//   <button data-calibration-reveal-target="toggle"
//           data-action="calibration-reveal#toggleNamed">Show names</button>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["dot", "toggle", "wallItem"]
  static values = {
    sessionId: String,
    revealPerson: { type: String, default: "" },
    // Compare pins — pinning implies discussing implies revealed.
    revealPersons: { type: Array, default: [] }
  }

  connect() {
    super.connect()
    this.state = this.loadState()
    const arriving = [this.revealPersonValue, ...this.revealPersonsValue].filter(Boolean)
    if (arriving.length) {
      this.state.ids = Array.from(new Set([...this.state.ids, ...arriving]))
      this.saveState()
    }
    this.apply()
  }

  toggleNamed() {
    this.state.named = !this.state.named
    this.saveState()
    this.apply()
  }

  // `calibration-pane` swaps the bottom pane without a page load, so the
  // arriving values on this element never change — it republishes the newly
  // opened / pinned ids here instead.
  onRevealed(event) {
    const arriving = (event.detail?.personIds || []).filter(Boolean)
    if (!arriving.length) return

    this.state.ids = Array.from(new Set([ ...this.state.ids, ...arriving ]))
    this.saveState()
    this.apply()
  }

  // The bottom pane is a Turbo Frame, so wall items arrive AFTER the last
  // apply() — Stimulus fires this as each one connects, and without it a
  // freshly-loaded wall would render every item unrevealed.
  wallItemTargetConnected(item) {
    // Can fire before connect() has loaded state; connect()'s own apply()
    // covers those items.
    if (this.state) this.applyWallItem(item)
  }

  // private

  // The text + name (detail half) follow the reveal automatically — free
  // text identifies people, so it cannot precede the name.
  applyWallItem(item) {
    const isRevealed = this.state.named || this.state.ids.includes(item.dataset.personId)
    const summary = item.querySelector("[data-reveal-role='summary']")
    const detail = item.querySelector("[data-reveal-role='detail']")
    if (summary) summary.classList.toggle("hidden", isRevealed)
    if (detail) detail.classList.toggle("hidden", !isRevealed)
    item.dataset.revealed = String(isRevealed)
  }

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
        // Initials stay on the dot either way (they're how the room points at
        // a column); the reveal governs the FULL name.
        dot.setAttribute("aria-label", `${dot.dataset.initials} — ${dot.dataset.baseLabel}. Open to discuss.`)
        dot.dataset.revealed = "false"
      }
    })
    this.wallItemTargets.forEach((item) => this.applyWallItem(item))
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

// Keeps a calibration session page's numbers live: the "ratings as of HH:MM"
// line, the ↻ Refresh button, and a poll that reloads the readiness +
// overview frame when the population's ratings or evidence move — then says
// what moved in a role="status" toast.
//
// Facilitators read the page as frozen when it wasn't: nothing said when it
// was computed, and the frame only re-fetched on a tab click. The poll asks a
// cheap endpoint for the latest write; only a changed stamp costs a reload.
//
// The automatic reload is HELD while a comparison drawer or a modal is open —
// a card the room is reading must never swap under it — and applied the
// moment they close. Refresh is the explicit ask and always applies.
//
// Example usage:
// <div data-controller="calibration-freshness"
//      data-calibration-freshness-url-value="/calibration_sessions/1/freshness"
//      data-calibration-freshness-stamp-value="2026-10-19T03:32:10.123456Z"
//      data-calibration-freshness-poll-value="true">
//   <time data-calibration-freshness-target="asOf" datetime="…">03:32</time>
//   <button data-action="calibration-freshness#refresh">↻ Refresh</button>
//   <div role="status" data-calibration-freshness-target="region"></div>
//   <template data-calibration-freshness-target="template">…[data-message]…</template>
//   <turbo-frame data-calibration-freshness-target="frame">
//     <div data-calibration-freshness-target="marker" data-stamp="…"></div>
//     <section data-readiness-coverage="78">…</section>
//   </turbo-frame>
// </div>

import BaseController from "controllers/base_controller"
import { get } from "@rails/request.js"

const TIME_FORMAT = new Intl.DateTimeFormat([], { hour: "2-digit", minute: "2-digit", hourCycle: "h23" })

export default class extends BaseController {
  static targets = ["frame", "asOf", "region", "template", "waitingTemplate", "marker", "refresh"]
  static values = {
    url: String,
    stamp: String,
    poll: Boolean,
    interval: { type: Number, default: 60000 }
  }

  connect() {
    super.connect()
    this.#localiseAsOf()
    this.onVisibility = () => this.#visibilityChanged()
    document.addEventListener("visibilitychange", this.onVisibility)
    this.#schedule()
  }

  disconnect() {
    this.#stopTimer()
    this.#stopWatching()
    document.removeEventListener("visibilitychange", this.onVisibility)
    super.disconnect()
  }

  intervalValueChanged() {
    if (this.element.dataset.connected !== undefined) this.#schedule()
  }

  // Any load of the frame — ours, a tab click, a cohort dot — rendered
  // fresh numbers, so the stamp and the as-of line follow it.
  markerTargetConnected(marker) {
    if (marker.dataset.stamp !== undefined) this.stampValue = marker.dataset.stamp
    this.#setAsOf(new Date())
    // Whatever reloaded the frame brought the held numbers with it.
    this.pending = null
    this.#stopWatching()
  }

  // A reload replaces the readiness card; keep the rater table as the
  // reader left it rather than snapping back to the server's default.
  keepDisclosure(event) {
    const current = this.frameTarget.querySelector("details[data-readiness-raters]")
    const next = event.detail.newFrame?.querySelector("details[data-readiness-raters]")
    if (current && next) next.open = current.open
  }

  async refresh() {
    if (this.hasRefreshTarget) this.refreshTarget.disabled = true
    try {
      await this.#check({ manual: true })
    } finally {
      if (this.hasRefreshTarget) this.refreshTarget.disabled = false
    }
  }

  // private

  #schedule() {
    this.#stopTimer()
    if (!this.pollValue || document.hidden) return

    this.timer = setInterval(() => this.#check({ manual: false }), this.intervalValue)
  }

  #stopTimer() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  #visibilityChanged() {
    if (document.hidden) return this.#stopTimer()

    this.#schedule()
    if (this.pollValue) this.#check({ manual: false })
  }

  async #check({ manual }) {
    if (this.checking) return
    this.checking = true
    try {
      const response = await get(this.urlValue, { query: { since: this.stampValue }, responseKind: "json" })
      if (!response.ok) {
        if (manual) this.#toast("Couldn't check for new ratings — try Refresh again.")
        return
      }
      const changes = await response.json

      if (!changes.changed && !manual) return this.#setAsOf(new Date())
      if (!manual && this.#held()) return this.#hold(changes)

      await this.#reload(changes)
    } catch {
      if (manual) this.#toast("Couldn't check for new ratings — try Refresh again.")
    } finally {
      this.checking = false
    }
  }

  async #reload(changes) {
    this.pending = null
    this.#stopWatching()
    const before = this.#coverage()
    const since = this.hasAsOfTarget ? this.asOfTarget.textContent.trim() : null

    await this.#loadFrame()
    this.#toast(this.#message(changes, since, before, this.#coverage()))
  }

  #loadFrame() {
    const frame = this.frameTarget
    return new Promise(resolve => {
      const done = () => {
        frame.removeEventListener("turbo:frame-load", done)
        frame.removeEventListener("turbo:fetch-request-error", done)
        resolve()
      }
      frame.addEventListener("turbo:frame-load", done)
      frame.addEventListener("turbo:fetch-request-error", done)
      const src = `${window.location.pathname}${window.location.search}`
      if (frame.getAttribute("src") === src) {
        frame.reload()
      } else {
        frame.src = src
      }
    })
  }

  // Held: remember the newest change and watch for the drawer or modal to
  // close. Later polls still ask from the page's own stamp, so the summary
  // applied on close covers everything that moved while it was held.
  #hold(changes) {
    this.pending = changes
    if (this.observer) return

    if (this.hasRegionTarget && this.hasWaitingTemplateTarget) {
      this.regionTarget.replaceChildren(this.waitingTemplateTarget.content.firstElementChild.cloneNode(true))
    }
    this.observer = new MutationObserver(() => {
      if (this.pending && !this.#held()) this.#reload(this.pending)
    })
    this.observer.observe(document.body, {
      subtree: true, childList: true, attributes: true, attributeFilter: ["class", "style"]
    })
  }

  #stopWatching() {
    this.observer?.disconnect()
    this.observer = null
    if (this.hasRegionTarget) this.regionTarget.querySelector("[data-freshness-waiting]")?.remove()
  }

  #held() {
    const drawer = document.querySelector("#calibration-comparison-drawer [data-comparison-drawer-target='body']")
    const drawerOpen = drawer && drawer.style.display !== "none"
    const modalOpen = document.querySelector("[data-modal-target='overlay']:not(.hidden)")
    return Boolean(drawerOpen || modalOpen)
  }

  #coverage() {
    const card = this.frameTarget.querySelector("[data-readiness-coverage]")
    return card ? Number(card.dataset.readinessCoverage) : null
  }

  #message(changes, since, before, after) {
    const parts = []
    const sinceText = since ? ` since ${since}` : ""
    if (changes.ratings_changed > 0) {
      const raters = changes.by_rater.map(({ name, count }) => `${name} ×${count}`).join(", ")
      parts.push(`${this.#plural(changes.ratings_changed, "rating")} changed${sinceText}${raters ? ` — ${raters}` : ""}.`)
    }
    if (changes.evidence_changed > 0) {
      parts.push(`${this.#plural(changes.evidence_changed, "feedback / evidence link")} changed${parts.length ? "" : sinceText}.`)
    }
    if (before !== null && after !== null && before !== after) parts.push(`Readiness ${before}% → ${after}%.`)
    if (parts.length === 0) parts.push(changes.changed ? "The numbers below are current." : `Nothing changed${sinceText}.`)

    return `${changes.changed ? "Updated just now" : "Up to date"} · ${parts.join(" ")}`
  }

  #plural(count, noun) {
    return `${count} ${noun}${count === 1 ? "" : "s"}`
  }

  #toast(text) {
    if (!this.hasRegionTarget || !this.hasTemplateTarget) return

    const toast = this.templateTarget.content.firstElementChild.cloneNode(true)
    toast.querySelector("[data-message]").textContent = text
    this.regionTarget.replaceChildren(toast)
  }

  #localiseAsOf() {
    if (!this.hasAsOfTarget) return
    const at = new Date(this.asOfTarget.getAttribute("datetime"))
    if (!Number.isNaN(at.getTime())) this.asOfTarget.textContent = TIME_FORMAT.format(at)
  }

  #setAsOf(date) {
    if (!this.hasAsOfTarget) return
    this.asOfTarget.setAttribute("datetime", date.toISOString())
    this.asOfTarget.textContent = TIME_FORMAT.format(date)
  }
}

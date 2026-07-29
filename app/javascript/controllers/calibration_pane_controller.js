// Drives the calibration drill-in's bottom pane (person card / evidence
// wall / compare tray) as a Turbo Frame instead of a page navigation.
//
// Why: every pane link — a dot, a tab, a pin, an unpin, the wall's filters
// — differs from the current URL only by query string. Left as full-page
// links they scroll the room back to the top on every click, hiding the
// card or tab they just opened. Setting the frame's `src` swaps only the
// pane (no scroll), and `history.pushState` keeps the URL shareable and
// the Back button honest — the matrix-frame pattern the framework explorer
// and the assessment views already use.
//
// Opening a dot or pinning someone is also the reveal gesture, so each
// navigation republishes the revealed ids for `calibration-reveal` (which
// lives on the same element and can't see inside the frame's swap).
//
// Example usage:
// <div data-controller="calibration-reveal calibration-pane"
//      data-action="click->calibration-pane#navigate">
//   <a href="?person=…">…</a>
//   <turbo-frame id="calibration-bottom-pane"
//                data-calibration-pane-target="frame">…</turbo-frame>
// </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["frame"]

  connect() {
    super.connect()
    this.onPopState = () => this.#load(new URL(window.location.href), { push: false })
    window.addEventListener("popstate", this.onPopState)
  }

  disconnect() {
    window.removeEventListener("popstate", this.onPopState)
  }

  // Delegated: any click inside the drill-in. Only links to THIS page
  // (same pathname, different query) are pane navigations — the back link,
  // the navbar, and any future off-page link fall through untouched.
  navigate(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey) return

    const link = event.target.closest("a[href]")
    if (!link || !this.hasFrameTarget) return
    if (link.dataset.paneNavigate === "false" || link.target === "_blank") return

    const url = new URL(link.href, window.location.origin)
    if (url.pathname !== window.location.pathname) return

    // Links rendered outside the frame (the grid's dots) freeze at page-load
    // state, so their pins and wall filters would be stale. Links inside the
    // frame own that state exactly — including an unpin that empties it — so
    // only the opted-in ones get the live values merged back in.
    if (link.dataset.paneKeepState === "true") this.#keepState(url)

    event.preventDefault()
    this.#load(url)
  }

  // Rewrites a full-page form's carried state (the ⚑ flag form lives
  // outside the frame, so its hidden fields go stale the same way).
  // The sweep covers the SERVER-rendered fields too (they carry the same
  // marker) — appending without removing would let a value the room
  // cleared in the frame ride along and come back on the redirect.
  stampState(event) {
    const form = event.target
    form.querySelectorAll("[data-pane-state='true']").forEach(field => field.remove())

    const current = new URL(window.location.href)
    const carried = [
      ...current.searchParams.getAll("compare[]").map(value => [ "compare[]", value ]),
      ...[ "person", "view", "wall_level", "wall_valence", "wall_rater" ]
        .filter(key => current.searchParams.get(key))
        .map(key => [ key, current.searchParams.get(key) ])
    ]
    carried.forEach(([ name, value ]) => {
      const field = document.createElement("input")
      field.type = "hidden"
      field.name = name
      field.value = value
      field.dataset.paneState = "true"
      form.appendChild(field)
    })
  }

  // The wall's filter form is a GET whose values belong in the same URL.
  submitFilters(event) {
    if (!this.hasFrameTarget) return

    event.preventDefault()
    const form = event.target
    const params = new URLSearchParams()
    for (const [key, value] of new FormData(form)) {
      if (value !== "") params.append(key, value)
    }
    const url = new URL(form.action, window.location.origin)
    url.search = params.toString()
    this.#load(url)
  }

  // private

  // Everything the link does NOT own: the pins and the wall's filters, so
  // stepping out to a person card and back returns to the wall the room was
  // reading. `view` and `person` are deliberately excluded — the dot owns
  // those (opening one IS "show me this person's card").
  #keepState(url) {
    const live = new URL(window.location.href).searchParams

    url.searchParams.delete("compare[]")
    live.getAll("compare[]").forEach(id => url.searchParams.append("compare[]", id))

    // `activity` (the log panel's open/closed state) is the pane
    // controller's, not the link's — carry it so a shared drill-in URL
    // keeps the panel as the room left it.
    for (const key of [ "wall_level", "wall_valence", "wall_rater", "activity" ]) {
      url.searchParams.delete(key)
      if (live.get(key)) url.searchParams.set(key, live.get(key))
    }
  }

  #load(url, { push = true } = {}) {
    this.frameTarget.src = `${url.pathname}${url.search}`
    if (push) history.pushState({}, "", url)
    this.#publishRevealed(url)
  }

  // The opened person and every pin count as revealed — the reveal
  // controller owns the sticky state, so hand it the ids rather than
  // reaching into its storage.
  #publishRevealed(url) {
    const params = url.searchParams
    const personIds = [params.get("person"), ...params.getAll("compare[]")].filter(Boolean)
    if (!personIds.length) return

    window.dispatchEvent(new CustomEvent("calibration:revealed", { detail: { personIds } }))
  }
}

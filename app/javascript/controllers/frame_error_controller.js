// Gives a lazy turbo-frame's failed load a voice (audit issues #328 / #365).
//
// A frame whose GET fails leaves its inline "Loading…" fallback standing
// forever: no error, no retry, and — inside a modal whose ×/Cancel live in the
// unloaded frame — no way out at all. This controller swaps that placeholder
// for an inline error block offering Retry (and, on a modal, Close).
//
// Three distinct failure shapes, all verified against turbo-rails 2.0.23:
//   - `turbo:fetch-request-error` — the network dropped, no response at all.
//   - `turbo:frame-missing` — a response with no matching frame (e.g. a 500
//     HTML body, or a session expiry bouncing the GET to the sign-in page).
//     Cancelled, because its default (`#handleFrameMissingFromResponse`)
//     renders Turbo's own "Content missing" into the frame and then throws
//     TurboFrameMissingError — it does NOT navigate; the `visit` in the event
//     detail is offered to a handler, never called for us.
//   - a response Turbo renders NOTHING from and complains about nowhere:
//     `FetchResponse#responseHTML` resolves undefined for any non-HTML content
//     type, so `FrameController#loadResponse` returns without rendering and
//     without dispatching `turbo:frame-missing`. A proxy's text/plain 502
//     reproduces the stuck-"Loading…" bug in total silence.
//
// LOADS ONLY — this controller speaks for the frame's own GET, never for a
// form submitted inside it. The two fetch events discriminate themselves (a
// FormSubmission's FetchRequest carries the FORM as its target, so
// `#isFrameEvent` excludes them), but `turbo:frame-missing` does NOT: Turbo
// dispatches it on `this.element` — the FRAME — unconditionally, including
// from `formSubmissionFailedWithResponse` → `loadResponse`. Claiming that
// would hide a whole editor/thread (along with the user's other typed edits)
// behind "Couldn't load…", whose Retry then re-GETs over their work. So
// frame-missing is claimed only while ARMED: `requestStarted` — which only
// fires for frame-targeted GETs — sets the flag, and a load's end
// (`loadSucceeded`, or `#failLoad`) clears it. Unarmed, the event falls
// through untouched to Turbo's default.
//
// The retry URL comes from `turbo:before-fetch-request` (whose detail carries
// the genuinely-requested URL), NOT from the frame's `src` attribute: Turbo
// rewrites `src` to the response's final URL whenever the fetch redirected
// (`FrameController#loadResponse`), so a GET bounced to a sign-in page would
// otherwise be retried forever against that page. Reading the URL off the
// event also means whichever controller points the frame needs no cooperation
// from this one.
//
// Usage — mount on an element wrapping ONE frame and its error block:
//   <div data-controller="frame-error"
//        data-action="turbo:before-fetch-request->frame-error#requestStarted
//                     turbo:fetch-request-error->frame-error#loadFailed
//                     turbo:frame-missing->frame-error#loadFailed
//                     turbo:before-fetch-response->frame-error#responseReceived
//                     turbo:frame-load->frame-error#loadSucceeded">
//     <turbo-frame id="…" loading="lazy" data-frame-error-target="frame">Loading…</turbo-frame>
//     <%= render Components::Kit::FrameLoadError.new(id: "…-error") %>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["frame", "error"]

  // A restored snapshot (Turbo Drive cache, or the browser's back button) can
  // reinstate this DOM mid-failure — frame hidden, error showing — but hands
  // it to a FRESH controller instance that never saw the failure. That state
  // is permanently dead: `requestedUrl` is unset so Retry silently no-ops, and
  // a hidden `loading="lazy"` frame can never re-fetch (an IntersectionObserver
  // sees nothing of a hidden element), so pointing its `src` goes into the
  // void. Reset to the truthful initial state instead: the frame's inline
  // "Loading…" (or its stale content) is accurate again, and every load path
  // works from there. This also means Retry is only ever reachable after a
  // failure THIS instance observed.
  connect() {
    super.connect()
    if (this.hasErrorTarget && !this.errorTarget.hidden) this.#showFrame()
  }

  // A fetch for our frame is starting: remember what it asked for, arm the
  // frame-missing claim (see the header — only a load may claim it), and take
  // any previous failure down — the "Loading…" placeholder is the truthful
  // state again.
  requestStarted(event) {
    if (!this.#isFrameEvent(event)) return
    const url = event.detail?.url
    if (url) this.requestedUrl = url.href || String(url)
    this.loading = true
    this.#showFrame()
  }

  // The frame's GET failed outright, or came back without the frame.
  loadFailed(event) {
    if (!this.#isFrameEvent(event)) return
    if (event.type === "turbo:frame-missing") {
      // Not ours: a form submitted inside the frame got a response with no
      // frame in it. Leave Turbo's default to handle it, and leave the form
      // (and everything typed into it) standing.
      if (!this.loading) return
      event.preventDefault()
    }
    this.#failLoad()
  }

  // The silent shape: a response Turbo discards without dispatching anything.
  responseReceived(event) {
    if (!this.#isFrameEvent(event)) return
    const response = event.detail?.fetchResponse
    if (!response) return
    // HTML is Turbo's own path: it either renders the frame or raises
    // `turbo:frame-missing`, which `loadFailed` above already owns.
    if (response.isHTML) return
    // A turbo-stream response belongs to Turbo's document-level stream
    // observer, which acts on this same event — not ours to claim.
    if ((response.contentType || "").includes("vnd.turbo-stream")) return
    this.#failLoad()
  }

  // A load landed — the frame speaks for itself now. Un-hiding it is the
  // symmetric half of `#failLoad`: a load this controller didn't initiate
  // (a `frame.reload()`) must never leave a hidden frame beside a hidden
  // error, which renders as empty content.
  loadSucceeded(event) {
    if (!this.#isFrameEvent(event)) return
    this.loading = false
    this.#showFrame()
  }

  // Re-fetch the frame from the URL it asked for.
  retry() {
    if (!this.hasFrameTarget || !this.requestedUrl) return
    this.#showFrame()

    const frame = this.frameTarget
    // Changing `src` is the whole retry — no `loading` flip needed. Turbo's
    // `#loadSourceURL` sets `#hasBeenLoaded` after the FIRST attempt whatever
    // its outcome, and `sourceURLChanged` fetches on `loading == eager ||
    // #hasBeenLoaded`. Two attribute writes, though, not one:
    // `#willHandleFrameMissingFromResponse` sets `complete` (which makes
    // `#loadSourceURL` bail), so clearing it first is required. The cleared
    // `src` fires `sourceURLChanged` too, but with no `sourceURL` it issues
    // no request; exactly one fetch leaves here, from the final assignment.
    frame.removeAttribute("complete")
    frame.removeAttribute("src")
    frame.src = this.requestedUrl
  }

  // private

  // Turbo's fetch events bubble, so these listeners also see form submissions
  // (whose target is the form) and any nested frame — only our own frame's
  // load drives this state.
  #isFrameEvent(event) {
    return this.hasFrameTarget && event.target === this.frameTarget
  }

  // Back to the frame (its "Loading…" placeholder) with no error showing.
  #showFrame() {
    if (this.hasErrorTarget) this.errorTarget.hidden = true
    if (this.hasFrameTarget) this.frameTarget.hidden = false
  }

  // Hiding the frame takes its stuck "Loading…" placeholder (or a previous
  // load's stale content) down with it, so the error is the whole body.
  // Focus follows it there: on a repeat failure the Retry the user just
  // pressed is inside the frame we hide, and focus would otherwise drop to
  // <body> — outside the dialog, with the announcement unread.
  #failLoad() {
    this.loading = false
    if (this.hasFrameTarget) this.frameTarget.hidden = true
    if (!this.hasErrorTarget) return
    this.errorTarget.hidden = false
    this.errorTarget.focus()
  }
}

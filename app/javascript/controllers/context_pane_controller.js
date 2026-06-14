// Context pane controller for the framework explorer's right-hand side pane.
//
// Owns the #suggestion-panel Turbo Frame src and the focus portion of the
// browser URL (`?focus=`, `?category_id=`, `?capability_id=`, `?level_ordinal=`).
// Combines focus state from matrix:focus-changed with role selection from
// tree:changed to build a fully-specified frame src. Skips rebuild when the
// computed src equals the current src (prevents duplicate fetches on no-op
// role changes at framework focus).
//
// Example markup:
//   <aside data-controller="context-pane"
//          data-context-pane-base-path-value="/frameworks/abc/suggestions"
//          data-context-pane-initial-role-ids-value="[...]"
//          data-context-pane-initial-track-value="both"
//          data-action="tree:changed@window->context-pane#onTreeChanged
//                       matrix:focus-changed@window->context-pane#onFocusChanged">
//     <turbo-frame id="suggestion-panel"
//                  data-context-pane-target="frame"></turbo-frame>
//   </aside>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["frame", "signal"]
  static values = {
    basePath: String,
    initialRoleIds: { type: Array, default: [] },
    initialTrack: { type: String, default: "both" }
  }

  connect() {
    super.connect()
    this.state = {
      focus: "framework",
      categoryId: null,
      capabilityId: null,
      levelOrdinal: null,
      expectationId: null,
      roleIds: [...this.initialRoleIdsValue],
      track: this.initialTrackValue
    }
    this.#hydrateFromUrl()

    // Browser back/forward changes the URL without re-mounting the
    // Stimulus controller, so the pane would stay stuck on the previous
    // focus unless we re-hydrate. Bind once on connect, unbind on
    // disconnect to avoid leaks on Turbo navigations.
    this.onPopState = () => this.#hydrateFromUrl()
    window.addEventListener("popstate", this.onPopState)

    this.#observeSyncSignal()
  }

  disconnect() {
    super.disconnect()
    window.removeEventListener("popstate", this.onPopState)
    this._syncObserver?.disconnect()
  }

  onTreeChanged(event) {
    const { roleIds, track } = event.detail || {}
    if (Array.isArray(roleIds)) this.state.roleIds = [...roleIds]
    if (typeof track === "string") this.state.track = track
    this.#rebuildFrameSrc()
    this.#pushBrowserUrl()
  }

  onFocusChanged(event) {
    const { level, categoryId, capabilityId, levelOrdinal, expectationId } = event.detail || {}
    this.state.focus = level || "framework"
    this.state.categoryId = categoryId || null
    this.state.capabilityId = capabilityId || null
    this.state.levelOrdinal = (typeof levelOrdinal === "number") ? levelOrdinal : null
    this.state.expectationId = expectationId || null
    this.#rebuildFrameSrc()
    this.#pushBrowserUrl()
  }

  // Dispatched by inline_editor_controller after any successful inline
  // edit or add (illustration / capability / category / expectation).
  // Reloads the panel so a freshly-landed pending suggestion appears in
  // the feed without a page refresh. #reload forces a re-fetch even when
  // the src hasn't changed.
  onSuggestionSubmitted() {
    if (!this.hasFrameTarget) return
    this.#rebuildFrameSrc()
    this.frameTarget.reload()
  }

  // Resets the explorer to framework-level focus — collapses any expanded row.
  clearFocus() {
    window.dispatchEvent(new CustomEvent("suggestion:navigate", {
      detail: { level: "framework", categoryId: null, capabilityId: null, levelOrdinal: null }
    }))
  }

  // Handles click on a suggestion row body — dispatches a navigation event
  // so the matrix controller can expand the relevant row and scroll to it.
  focusSuggestion(event) {
    const el = event.currentTarget
    const detail = {
      level: el.dataset.navLevel || "framework",
      categoryId: el.dataset.navCategoryId || null,
      capabilityId: el.dataset.navCapabilityId || null,
      levelOrdinal: el.dataset.navLevelOrdinal ? parseInt(el.dataset.navLevelOrdinal, 10) : null
    }

    window.dispatchEvent(new CustomEvent("suggestion:navigate", { detail }))
  }

  // private

  // Reloads the feed frame whenever a framework activity event broadcasts a
  // replacement of the hidden sync-signal element. Mirrors the assessment
  // sync controller — the reload is unconditional (no self-suppression): the
  // feed frame is the only thing that re-fetches, so there's no matrix flicker
  // or scroll reset to guard against, and the actor should see their own entry.
  #observeSyncSignal() {
    if (!this.hasSignalTarget) return

    this._syncObserver = new MutationObserver(() => {
      if (this.hasFrameTarget) this.frameTarget.reload()
    })
    this._syncObserver.observe(this.signalTarget.parentElement, {
      childList: true,
      subtree: false
    })
  }

  // Reads focus params from the browser URL into state. Called on connect
  // AND on popstate — browser back/forward can remove params just as
  // easily as add them, so reset focus state before repopulating.
  #hydrateFromUrl() {
    const url = new URL(window.location.href)
    this.state.focus = url.searchParams.get("focus") || "framework"
    this.state.categoryId = url.searchParams.get("category_id") || null
    this.state.capabilityId = url.searchParams.get("capability_id") || null
    const levelOrdinal = url.searchParams.get("level_ordinal")
    this.state.levelOrdinal = levelOrdinal ? parseInt(levelOrdinal, 10) : null

    // Always prime the frame src on connect — in edit mode the pane is
    // visible at page load and Turbo's lazy fetch fires immediately, so we
    // need the focused URL set before (or quickly after) that first fetch.
    // #rebuildFrameSrc short-circuits when the computed URL equals current,
    // so re-priming with a non-focused state costs nothing.
    this.#rebuildFrameSrc()
  }

  #rebuildFrameSrc() {
    if (!this.hasFrameTarget || !this.basePathValue) return

    const url = new URL(this.basePathValue, window.location.origin)
    url.searchParams.set("layout", "panel")

    if (this.state.focus && this.state.focus !== "framework") {
      url.searchParams.set("focus", this.state.focus)
    }
    if (this.state.categoryId) url.searchParams.set("category_id", this.state.categoryId)
    if (this.state.capabilityId) url.searchParams.set("capability_id", this.state.capabilityId)
    if (this.state.levelOrdinal != null) {
      url.searchParams.set("level_ordinal", this.state.levelOrdinal.toString())
    }
    this.state.roleIds.forEach(id => url.searchParams.append("roles[]", id))
    if (this.state.track && this.state.track !== "both") {
      url.searchParams.set("track", this.state.track)
    }

    const next = url.toString()
    if (this.frameTarget.src === next) return
    this.frameTarget.src = next
  }

  #pushBrowserUrl() {
    const url = new URL(window.location.href)
    const keysToClear = ["focus", "category_id", "capability_id", "level_ordinal"]

    // Clear focus params first; re-add only the relevant ones.
    keysToClear.forEach(k => url.searchParams.delete(k))

    if (this.state.focus && this.state.focus !== "framework") {
      url.searchParams.set("focus", this.state.focus)
    }
    if (this.state.categoryId) url.searchParams.set("category_id", this.state.categoryId)
    if (this.state.capabilityId) url.searchParams.set("capability_id", this.state.capabilityId)
    if (this.state.levelOrdinal != null) {
      url.searchParams.set("level_ordinal", this.state.levelOrdinal.toString())
    }

    if (url.toString() !== window.location.href) {
      window.history.pushState({}, "", url)
    }
  }
}

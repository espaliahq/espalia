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
      suggestionId: null,
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

    // Catch-up hooks for reloads skipped while a draft was open: fire on
    // focus leaving a composer and on input (covers clearing the text).
    this.onComposerSettle = () => setTimeout(() => this.#catchUpAfterComposer(), 0)
    this.element.addEventListener("focusout", this.onComposerSettle)
    this.element.addEventListener("input", this.onComposerSettle)
  }

  disconnect() {
    super.disconnect()
    window.removeEventListener("popstate", this.onPopState)
    this.element.removeEventListener("focusout", this.onComposerSettle)
    this.element.removeEventListener("input", this.onComposerSettle)
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
    // An explicit matrix interaction moves focus — including out of a
    // suggestion card (most-specific-wins, same as every other level).
    this.state.suggestionId = null
    this.#rebuildFrameSrc()
    this.#pushBrowserUrl()
  }

  // Opens the pane's suggestion card (focus=suggestion) from an entry's
  // discussion affordance. Deliberately does NOT navigate the matrix —
  // matrix:focus-changed would immediately overwrite this focus (the row
  // body click remains the way to jump the grid to the entity).
  openSuggestionCard(event) {
    const id = event.currentTarget?.dataset?.suggestionId
    if (!id) return
    this.state.focus = "suggestion"
    this.state.suggestionId = id
    this.state.categoryId = null
    this.state.capabilityId = null
    this.state.levelOrdinal = null
    this.state.expectationId = null
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
    this.state.suggestionId = null
    window.dispatchEvent(new CustomEvent("suggestion:navigate", {
      detail: { level: "framework", categoryId: null, capabilityId: null, levelOrdinal: null }
    }))
  }

  // Handles click on a suggestion row body — dispatches a navigation event
  // so the matrix controller can expand the relevant row and scroll to it.
  focusSuggestion(event) {
    // The entry's inline action controls (approve / reject / review) act on the
    // suggestion — activating one (mouse or keyboard) must not also navigate the
    // matrix. Bail before preventDefault so the control behaves normally.
    if (event.target.closest("button, a")) return

    // Stop the space key from scrolling the page when a keyboard user
    // activates a navigable entry (role="button" rows). No-op for clicks.
    if (event.type === "keydown") event.preventDefault()

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
      if (!this.hasFrameTarget) return
      // Never reload over a half-written comment: a broadcast landing while
      // the suggestion card's composer (or an inline reply/edit form) is
      // focused or holds an edited draft would destroy it. The skipped
      // reload is remembered and re-fired once the composers are clean
      // again (see #catchUpAfterComposer).
      if (this.#composerDirty()) {
        this._missedReload = true
        return
      }
      this.frameTarget.reload()
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
    this.state.suggestionId = url.searchParams.get("suggestion_id") || null

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
    if (this.state.focus === "suggestion" && this.state.suggestionId) {
      url.searchParams.set("suggestion_id", this.state.suggestionId)
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

  // Whether any textarea in the pane is focused or holds an unsent DRAFT —
  // the guard that keeps broadcast reloads from eating comment drafts.
  // Dirty means the value DIFFERS from the server-rendered defaultValue:
  // the hidden per-comment edit forms are prefilled with the comment body,
  // so a non-empty check would flag every viewer who has ever commented
  // and suppress reloads permanently.
  #composerDirty() {
    const areas = this.element.querySelectorAll("textarea")
    return Array.from(areas).some(
      t => t.value !== t.defaultValue || t === document.activeElement
    )
  }

  // A reload skipped while a draft was in flight is re-armed here: once
  // every composer is clean again (submit clears it, cancel restores the
  // defaultValue, blur releases focus), the missed reload fires so the
  // pane catches up instead of staying stale until the next broadcast.
  #catchUpAfterComposer() {
    if (!this._missedReload) return
    if (this.#composerDirty()) return
    this._missedReload = false
    if (this.hasFrameTarget) this.frameTarget.reload()
  }

  #pushBrowserUrl() {
    const url = new URL(window.location.href)
    const keysToClear = ["focus", "category_id", "capability_id", "level_ordinal", "suggestion_id"]

    // Clear focus params first; re-add only the relevant ones.
    keysToClear.forEach(k => url.searchParams.delete(k))

    if (this.state.focus && this.state.focus !== "framework") {
      url.searchParams.set("focus", this.state.focus)
    }
    if (this.state.focus === "suggestion" && this.state.suggestionId) {
      url.searchParams.set("suggestion_id", this.state.suggestionId)
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

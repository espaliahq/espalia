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
  static targets = ["frame"]
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

  // Reads focus/role params from the browser URL so that a deep-link reload
  // restores state for the panel (the matrix already reads roles/track itself).
  #hydrateFromUrl() {
    const url = new URL(window.location.href)
    const focus = url.searchParams.get("focus")
    if (focus) this.state.focus = focus
    const categoryId = url.searchParams.get("category_id")
    if (categoryId) this.state.categoryId = categoryId
    const capabilityId = url.searchParams.get("capability_id")
    if (capabilityId) this.state.capabilityId = capabilityId
    const levelOrdinal = url.searchParams.get("level_ordinal")
    if (levelOrdinal) this.state.levelOrdinal = parseInt(levelOrdinal, 10)

    // If URL includes any focus param, prime the frame on connect so deep
    // links load the filtered panel.
    if (focus || categoryId || capabilityId || levelOrdinal) {
      this.#rebuildFrameSrc()
    }
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

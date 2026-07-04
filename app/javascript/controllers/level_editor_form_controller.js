// Points the shared "Edit levels" modal's `level-editor` Turbo Frame at the
// role whose kebab opened it, and asks the matrix to re-fetch after each
// successful in-frame save (level titles/codes render in the matrix header,
// which the frame re-render can't reach).
//
// On the window `modal:open` event (dispatched by the modal controller with
// the trigger's dataset) it self-gates on `levelEditorRoleId` and sets the
// frame `src` to the levels index for that role. A cache-buster forces a
// refetch even when the same role is reopened, so the list reflects the
// latest state.
//
// Usage:
//   <div data-controller="level-editor-form"
//        data-level-editor-form-levels-url-value="/frameworks/:id/levels"
//        data-action="turbo:submit-end->level-editor-form#submitted">
//     <turbo-frame id="level-editor" data-level-editor-form-target="frame"></turbo-frame>
//   </div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame"]
  static values = { levelsUrl: String }

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  // In-frame saves (row save / entry move / add) bubble turbo:submit-end up
  // to this wrapper — on success, the acting user's matrix re-fetches so the
  // header badges match (same wiring shape as suggestion:resolved → refresh).
  submitted(event) {
    if (event.detail?.success === false) return

    window.dispatchEvent(new CustomEvent("org-structure:updated"))
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to "Edit levels…" triggers (others share the modal:open bus).
    if (data.levelEditorRoleId === undefined) return
    if (!this.hasFrameTarget || !this.levelsUrlValue) return

    const url = new URL(this.levelsUrlValue, window.location.origin)
    url.searchParams.set("role_id", data.levelEditorRoleId || "")
    url.searchParams.set("_", Date.now().toString())
    this.frameTarget.src = url.pathname + url.search
  }
}

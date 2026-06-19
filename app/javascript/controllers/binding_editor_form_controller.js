// Points the shared "Edit roles" modal's `binding-editor` Turbo Frame at the
// capability whose row-actions kebab opened it. On the window `modal:open` event
// (dispatched by the modal controller with the trigger's dataset), it sets the
// frame `src` to the capability-bindings index, so the editor lazy-loads for
// that capability. A cache-buster forces a refetch even when the same capability
// is reopened, so the list reflects the latest state.
//
// Usage:
//   <div data-controller="binding-editor-form"
//        data-binding-editor-form-bindings-url-value="/frameworks/:id/capability_bindings">
//     <turbo-frame id="binding-editor" data-binding-editor-form-target="frame"></turbo-frame>
//   </div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame"]
  static values = { bindingsUrl: String }

  connect() {
    this._onOpen = this.#onOpen.bind(this)
    window.addEventListener("modal:open", this._onOpen)
  }

  disconnect() {
    window.removeEventListener("modal:open", this._onOpen)
  }

  // private

  #onOpen(event) {
    const data = event.detail?.dataset || {}
    // Only respond to "Edit roles…" triggers (others share the modal:open bus).
    if (data.bindingEditorCapabilityId === undefined) return
    if (!this.hasFrameTarget || !this.bindingsUrlValue) return

    const url = new URL(this.bindingsUrlValue, window.location.origin)
    url.searchParams.set("capability_id", data.bindingEditorCapabilityId || "")
    url.searchParams.set("_", Date.now().toString())
    this.frameTarget.src = url.pathname + url.search
  }
}

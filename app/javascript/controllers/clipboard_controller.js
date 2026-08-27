// Copies the text of a source element to the clipboard and gives the user
// brief "Copied!" feedback on the button.
//
// Usage:
//   <div data-controller="clipboard">
//     <code data-clipboard-target="source">https://app/mcp</code>
//     <button type="button"
//             data-action="clipboard#copy"
//             data-clipboard-target="button"
//             data-clipboard-label-value="Copy">Copy</button>
//   </div>
//
// Icon buttons swap two glyphs instead of rewriting a label — the text path
// would destroy an inline <svg>, since it assigns textContent:
//
//   <div data-controller="clipboard">
//     <span class="sr-only" data-clipboard-target="source">https://app/mcp</span>
//     <button type="button" data-action="clipboard#copy" aria-label="Copy link">
//       <svg data-clipboard-target="idle">…link…</svg>
//       <svg data-clipboard-target="copied" class="hidden">…check…</svg>
//     </button>
//   </div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["source", "button", "idle", "copied"]
  static values = {
    label: { type: String, default: "Copy" },
    copied: { type: String, default: "Copied!" }
  }

  disconnect() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
    super.disconnect()
  }

  async copy() {
    const text = this.sourceTarget.textContent.trim()

    try {
      await navigator.clipboard.writeText(text)
    } catch {
      // Clipboard API can be unavailable (insecure context, denied
      // permission). Fall back to a hidden textarea + execCommand.
      this.fallbackCopy(text)
    }

    // Optimistic feedback regardless of which path succeeded — the user
    // sees confirmation and we don't leak failures for a non-critical action.
    this.flashCopied()
  }

  // private

  fallbackCopy(text) {
    const area = document.createElement("textarea")
    area.value = text
    area.setAttribute("readonly", "")
    area.style.position = "absolute"
    area.style.left = "-9999px"
    document.body.appendChild(area)
    area.select()
    try {
      document.execCommand("copy")
    } catch {
      // Nothing more we can do — leave the feedback optimistic.
    }
    document.body.removeChild(area)
  }

  flashCopied() {
    // Icon form: swap glyphs. Assigning textContent (the label form below)
    // would wipe the button's inline <svg> on the first copy.
    if (this.hasIdleTarget && this.hasCopiedTarget) {
      this.#showCopiedIcon(true)
      this.#restoreAfterFlash(() => this.#showCopiedIcon(false))
      return
    }

    if (!this.hasButtonTarget) return

    this.buttonTarget.textContent = this.copiedValue
    this.#restoreAfterFlash(() => { this.buttonTarget.textContent = this.labelValue })
  }

  #showCopiedIcon(copied) {
    this.idleTarget.classList.toggle("hidden", copied)
    this.copiedTarget.classList.toggle("hidden", !copied)
  }

  #restoreAfterFlash(restore) {
    if (this._timer) clearTimeout(this._timer)
    this._timer = setTimeout(() => {
      restore()
      this._timer = null
    }, 2000)
  }
}

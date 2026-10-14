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

const WRITE_TIMEOUT_MS = 1000

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
    if (await this.write(text)) this.flashCopied()
  }

  // private

  // Resolves true only once the text is on the clipboard. A browser can leave
  // writeText pending forever (headless Chromium with no clipboard backend), so
  // a write that hasn't settled in time falls back to execCommand, which
  // answers synchronously while the click's user activation still holds.
  write(text) {
    if (!navigator.clipboard?.writeText) return Promise.resolve(this.fallbackCopy(text))

    return new Promise((resolve) => {
      let settled = false
      const settle = (copied) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve(copied)
      }
      const timer = setTimeout(() => settle(this.fallbackCopy(text)), WRITE_TIMEOUT_MS)

      navigator.clipboard.writeText(text).then(
        () => settle(true),
        () => settle(this.fallbackCopy(text))
      )
    })
  }

  fallbackCopy(text) {
    const area = document.createElement("textarea")
    area.value = text
    area.setAttribute("readonly", "")
    area.style.position = "absolute"
    area.style.left = "-9999px"
    document.body.appendChild(area)
    area.select()
    try {
      return document.execCommand("copy")
    } catch {
      return false
    } finally {
      document.body.removeChild(area)
    }
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

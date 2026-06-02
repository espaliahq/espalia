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

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["source", "button"]
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
    if (!this.hasButtonTarget) return

    this.buttonTarget.textContent = this.copiedValue
    if (this._timer) clearTimeout(this._timer)
    this._timer = setTimeout(() => {
      this.buttonTarget.textContent = this.labelValue
      this._timer = null
    }, 2000)
  }
}

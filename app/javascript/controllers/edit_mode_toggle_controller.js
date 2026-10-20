// Segmented toggle between Editing and Suggesting within the Framework
// Explorer's edit mode.
//
// Writes the user's choice to a long-lived cookie (`framework_edit_mode`).
// The backend FrameworkEditMode concern reads it on every inline-edit
// submission and maps it to the CommandHandler's `mode:` kwarg. The
// toggle itself is instant client-side — no server round-trip on select.
//
// Example usage:
//   <div data-controller="edit-mode-toggle" data-edit-mode-toggle-value-value="editing">
//     <button data-action="edit-mode-toggle#select"
//             data-edit-mode-toggle-target="editingButton"
//             data-edit-mode-value="editing">Editing</button>
//     <button data-action="edit-mode-toggle#select"
//             data-edit-mode-toggle-target="suggestingButton"
//             data-edit-mode-value="suggesting">Suggesting</button>
//   </div>
//
import BaseController from "controllers/base_controller"

const COOKIE_NAME = "framework_edit_mode"
const COOKIE_MAX_AGE_SECONDS = 60 * 60 * 24 * 365

export default class extends BaseController {
  static targets = ["editingButton", "suggestingButton"]

  connect() {
    super.connect()
    this.applyStyling(this.currentMode())
  }

  select(event) {
    const mode = event.currentTarget.dataset.editModeValue
    if (mode !== "editing" && mode !== "suggesting") return

    this.writeCookie(mode)
    this.applyStyling(mode)
    // The shared inline editor derives its Save-vs-Propose label from this mode
    // plus the viewer's server-computed authority, so it needs to hear the flip
    // immediately — not on the next page load.
    window.dispatchEvent(new CustomEvent("framework-edit-mode:changed", {
      bubbles: true,
      detail: { mode: mode }
    }))
  }

  // private

  currentMode() {
    return this.readCookie() === "suggesting" ? "suggesting" : "editing"
  }

  applyStyling(mode) {
    const editingActive = mode === "editing"
    if (this.hasEditingButtonTarget) {
      this.setPressed(this.editingButtonTarget, editingActive)
    }
    if (this.hasSuggestingButtonTarget) {
      this.setPressed(this.suggestingButtonTarget, !editingActive)
    }
  }

  // Kit::SegmentedControl styles the pressed segment from the attribute alone
  setPressed(button, pressed) {
    button.setAttribute("aria-pressed", pressed ? "true" : "false")
  }

  readCookie() {
    const match = document.cookie.match(new RegExp("(?:^|; )" + COOKIE_NAME + "=([^;]+)"))
    return match ? decodeURIComponent(match[1]) : null
  }

  writeCookie(value) {
    document.cookie =
      `${COOKIE_NAME}=${encodeURIComponent(value)}; ` +
      `path=/; max-age=${COOKIE_MAX_AGE_SECONDS}; SameSite=Lax`
  }
}

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
  static classes = ["active", "inactive"]

  connect() {
    super.connect()
    this.applyStyling(this.currentMode())
  }

  select(event) {
    const mode = event.currentTarget.dataset.editModeValue
    if (mode !== "editing" && mode !== "suggesting") return

    this.writeCookie(mode)
    this.applyStyling(mode)
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

  setPressed(button, pressed) {
    button.setAttribute("aria-pressed", pressed ? "true" : "false")
    // Active / inactive CSS classes are provided by the view via
    // `data-edit-mode-toggle-active-class` / `-inactive-class` so the
    // controller stays styling-agnostic.
    if (this.hasActiveClass && this.hasInactiveClass) {
      if (pressed) {
        button.classList.remove(...this.inactiveClasses)
        button.classList.add(...this.activeClasses)
      } else {
        button.classList.remove(...this.activeClasses)
        button.classList.add(...this.inactiveClasses)
      }
    }
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

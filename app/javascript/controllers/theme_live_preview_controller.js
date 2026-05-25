// Live-preview the tenant theme form. On every `input` event from a
// color picker or font input, sets the corresponding CSS variable on
// document.documentElement so the running page repaints immediately.
// Revert restores each field to its server-rendered default and
// re-applies, so unsaved changes can be discarded.
//
// On disconnect (Turbo navigation away from the editor without
// pressing Save), every preview variable this controller wrote is
// removed from documentElement.style, so the persisted
// `<style id="tenant-theme">` takes back over. Without this cleanup,
// inline overrides would persist across the rest of the user's
// session, defeating Cancel.
//
// Dark-mode caveat: dark color variables are scoped under a
// `@media (prefers-color-scheme: dark)` rule by the layout's
// <style id="tenant-theme">. Writing to documentElement.style applies
// at the inline-style level, which the media query overrides only
// when the user's OS is in dark mode. So light-mode previews are
// invisible when the OS is dark, and vice-versa — acceptable trade-off.
//
// Usage:
// <form data-controller="theme-live-preview">
//   <input type="color" name="tenant[primary_color]"
//          value="#32c8c8"
//          data-theme-live-preview-target="field"
//          data-theme-live-preview-var-param="--color-primary"
//          data-theme-live-preview-mode-param="light"
//          data-theme-live-preview-default-param="#32c8c8"
//          data-action="input->theme-live-preview#apply">
//   <button type="button" data-action="theme-live-preview#revert">Cancel</button>
// </form>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["field"]

  connect() {
    super.connect()
    this._previewVars = new Set()
  }

  disconnect() {
    if (this._previewVars) {
      this._previewVars.forEach((varName) => {
        document.documentElement.style.removeProperty(varName)
      })
      this._previewVars.clear()
    }
    super.disconnect()
  }

  apply(event) {
    const el = event.currentTarget
    const varName = el.dataset.themeLivePreviewVarParam
    const mode = el.dataset.themeLivePreviewModeParam
    if (!varName) return

    // Only preview the value for the OS color scheme actually being
    // rendered. Without this, light + dark fields share a CSS variable
    // and clobber each other (especially during revert, where the
    // last-written value wins regardless of OS mode).
    if (mode === "light" && this.prefersDark) return
    if (mode === "dark" && !this.prefersDark) return

    const rawValue = el.value
    const finalValue = varName === "--font-sans" && rawValue.length > 0
      ? `"${rawValue}", ui-sans-serif, system-ui, sans-serif`
      : rawValue
    document.documentElement.style.setProperty(varName, finalValue)
    this._previewVars.add(varName)
  }

  revert(event) {
    event.preventDefault()
    this.fieldTargets.forEach((field) => {
      const defaultValue = field.dataset.themeLivePreviewDefaultParam
      field.value = defaultValue
      field.dispatchEvent(new Event("input", { bubbles: true }))
    })
  }

  get prefersDark() {
    return window.matchMedia("(prefers-color-scheme: dark)").matches
  }
}

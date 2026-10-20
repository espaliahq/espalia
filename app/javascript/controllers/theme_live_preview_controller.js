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
// Light and dark fields write their own variables (`--tenant-brand`,
// `--tenant-brand-dark`), and theme/roles.css shows whichever the page's
// scheme calls for. The admin flips the scheme to preview the other half.
//
// Usage:
// <form data-controller="theme-live-preview">
//   <input type="color" name="tenant[custom_theme][brand][light]"
//          value="#32c8c8"
//          data-theme-live-preview-target="field"
//          data-theme-live-preview-var-param="--tenant-brand"
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
    if (!varName) return

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
}

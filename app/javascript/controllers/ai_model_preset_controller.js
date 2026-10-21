// Fills the AI model form from a preset, and shows the effort field only for
// an Anthropic provider.
//
// A preset is a convenience: it sets the generic provider, address and model
// fields and nothing else, so what is saved is never "a gateway", only a
// provider kind at an address.
//
// Usage:
//   <form data-controller="ai-model-preset"
//         data-ai-model-preset-presets-value='{"anthropic":{"provider":"anthropic","base_url":null,"model":"claude-opus-5-5"}}'>
//     <select data-ai-model-preset-target="preset" data-action="change->ai-model-preset#apply">…</select>
//     <select data-ai-model-preset-target="provider" data-action="change->ai-model-preset#providerChanged">…</select>
//     <input data-ai-model-preset-target="baseUrl">
//     <input data-ai-model-preset-target="model">
//     <div data-ai-model-preset-target="effortRow">…</div>
//   </form>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["preset", "provider", "baseUrl", "model", "effortRow"]
  static values = { presets: Object }

  connect() {
    super.connect()
    this.providerChanged()
  }

  apply() {
    const preset = this.presetsValue[this.presetTarget.value]
    if (!preset) return

    this.providerTarget.value = preset.provider
    this.baseUrlTarget.value = preset.base_url || ""
    this.modelTarget.value = preset.model || ""
    this.providerChanged()
  }

  providerChanged() {
    this.effortRowTarget.hidden = this.providerTarget.value !== "anthropic"
  }
}

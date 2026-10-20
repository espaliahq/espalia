// Live-preview the Theme page. Choosing a preset sets `data-theme` on <html>;
// under Custom, each field writes its variable (`--tenant-brand`,
// `--tenant-brand-dark`, `--font-sans`) onto the page and onto Custom's
// preview frames, where theme/roles.css derives the rest. Each readout shows
// its colour and the text the contrast helper picked for it.
//
// The stored `#tenant-theme` sheet is switched off while the editor is open,
// on the page and in Custom's frames, so the fields alone drive the preview: a
// preset shows without the saved Custom values, and a cleared field shows
// Default. Cancel puts the choice and fields back; leaving the page restores
// what was there.
// Each frame is drawn at a phone's size and scaled to its box.

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["theme", "custom", "field", "frame", "readout"]

  connect() {
    super.connect()
    this.root = document.documentElement
    this.originalTheme = this.root.dataset.theme
    this.storedSheet = document.getElementById("tenant-theme")?.sheet
    if (this.storedSheet) this.storedSheet.disabled = true
    this.painted = new WeakMap()
    this.resizer = new ResizeObserver((entries) => entries.forEach(({ target }) => this.fit(target)))
    this.frameTargets.forEach((frame) => this.resizer.observe(frame.parentElement))
    this.render()
  }

  disconnect() {
    this.resizer.disconnect()
    this.paint(this.root, {})
    this.setPreset(this.originalTheme)
    if (this.storedSheet) this.storedSheet.disabled = false
    super.disconnect()
  }

  chooseTheme() {
    this.render()
  }

  apply() {
    this.render()
  }

  frameLoaded() {
    this.render()
  }

  revert(event) {
    event.preventDefault()
    this.themeTargets.forEach((radio) => { radio.checked = radio.defaultChecked })
    this.fieldTargets.forEach((field) => { field.value = field.defaultValue })
    this.render()
  }

  render() {
    const theme = this.themeTargets.find((radio) => radio.checked)?.value || "default"
    const custom = theme === "custom"
    const variables = this.customVariables()

    this.customTarget.hidden = !custom
    this.customTarget.disabled = !custom
    this.setPreset(custom || theme === "default" ? undefined : theme)
    this.paint(this.root, custom ? variables : {})
    this.customFrames().forEach((frame) => {
      const doc = frame.contentDocument
      if (!doc?.documentElement) return
      const storedSheet = doc.getElementById("tenant-theme")?.sheet
      if (storedSheet) storedSheet.disabled = true
      this.paint(doc.documentElement, variables)
    })
    this.updateReadouts()
  }

  // Scales a frame, drawn at a fixed size, to the width of its box.
  fit(box) {
    const frame = box.querySelector("iframe")
    frame.style.scale = box.clientWidth / frame.offsetWidth
  }

  setPreset(theme) {
    if (theme) {
      this.root.dataset.theme = theme
    } else {
      delete this.root.dataset.theme
    }
  }

  customVariables() {
    return Object.fromEntries(this.fieldTargets
      .filter((field) => field.value.trim().length > 0)
      .map((field) => {
        const name = field.dataset.variable
        const value = name === "--font-sans"
          ? `"${field.value.trim()}", ui-sans-serif, system-ui, sans-serif`
          : field.value
        return [name, value]
      }))
  }

  // Sets the variables on an element, removing any this controller set there before.
  paint(element, variables) {
    const previous = this.painted.get(element) || []
    previous.forEach((name) => { if (!(name in variables)) element.style.removeProperty(name) })
    Object.entries(variables).forEach(([name, value]) => element.style.setProperty(name, value))
    this.painted.set(element, Object.keys(variables))
  }

  customFrames() {
    return this.frameTargets.filter((frame) => frame.dataset.theme === "custom")
  }

  // Shows the picked colour and the text on it. Where CSS darkens the colour for
  // its element (brand-strong under buttons), shows that fill instead of claiming
  // the text sits on the picked colour.
  updateReadouts() {
    this.readoutTargets.forEach((readout) => {
      const { role, scheme, element, text: label, shade } = readout.dataset
      const field = this.fieldTargets.find((f) => f.name === `tenant[custom_theme][${role}][${scheme}]`)
      const frame = this.customFrames().find((f) => f.dataset.scheme === scheme)
      const sample = frame?.contentDocument?.querySelector(element)
      const hex = this.code(field.value)

      if (!sample) return readout.replaceChildren(hex)

      // A button's colour transition would otherwise report the colour it is leaving.
      sample.getAnimations().forEach((animation) => animation.finish())
      const style = frame.contentWindow.getComputedStyle(sample)
      const text = this.blackOrWhite(style.color)
      const fill = this.rgb(style.backgroundColor)
      if (shade && !this.sameColour(fill, this.rgb(field.value))) {
        readout.replaceChildren(hex, this.shadeNote(fill, `${shade}, with ${text} text`))
      } else {
        readout.replaceChildren(hex, ` · ${label} ${text}`)
      }
    })
  }

  code(value) {
    const span = document.createElement("span")
    span.className = "font-mono"
    span.textContent = value
    return span
  }

  shadeNote([r, g, b], words) {
    const note = document.createElement("span")
    note.className = "mt-1 flex items-start gap-1.5"
    note.dataset.themeShade = ""
    const swatch = document.createElement("span")
    swatch.className = "mt-0.5 size-3 shrink-0 rounded-xs border border-default"
    swatch.style.backgroundColor = `rgb(${r}, ${g}, ${b})`
    swatch.setAttribute("aria-hidden", "true")
    note.append(swatch, words)
    return note
  }

  blackOrWhite(color) {
    const [r, g, b] = this.rgb(color)
    return r + g + b > 382 ? "white" : "black"
  }

  // Within rounding of the oklch round trip, which can shift a channel by one.
  sameColour(a, b) {
    return a.every((channel, i) => Math.abs(channel - b[i]) <= 2)
  }

  // Resolves any CSS colour (rgb, oklch, color(srgb-linear …)) through a canvas pixel.
  rgb(color) {
    this.pixel ||= document.createElement("canvas").getContext("2d", { willReadFrequently: true })
    this.pixel.clearRect(0, 0, 1, 1)
    this.pixel.fillStyle = "#000"
    this.pixel.fillStyle = color
    this.pixel.fillRect(0, 0, 1, 1)
    return [...this.pixel.getImageData(0, 0, 1, 1).data.slice(0, 3)]
  }
}

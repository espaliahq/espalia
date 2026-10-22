// Auto / Light / Dark in the user menu: paints the page at once, then saves.
//
// <div data-controller="color-scheme"
//      data-color-scheme-url-value="/settings/color_scheme"
//      data-color-scheme-light-color-value="#ffffff"
//      data-color-scheme-dark-color-value="#0f172a">
//   <button role="menuitemradio" aria-checked="true"
//           data-color-scheme-target="option"
//           data-color-scheme-scheme-param="auto"
//           data-action="color-scheme#choose">Auto</button>
// </div>

import BaseController from "controllers/base_controller"
import { patch } from "@rails/request.js"

export default class extends BaseController {
  static targets = ["option"]
  static values = { url: String, lightColor: String, darkColor: String }

  #requests = 0
  #saved
  #savedRequest = 0
  // One save at a time, so the server can't store an older choice after a newer one
  #saveQueue = Promise.resolve(true)

  connect() {
    super.connect()
    this.#saved = this.#current()
  }

  async choose({ params: { scheme } }) {
    if (scheme === this.#current()) return

    const request = ++this.#requests
    this.#apply(scheme)
    if (await this.#save(scheme)) {
      if (request > this.#savedRequest) [this.#saved, this.#savedRequest] = [scheme, request]
    } else if (request === this.#requests) {
      this.#apply(this.#saved)
    }
  }

  // private

  #save(scheme) {
    this.#saveQueue = this.#saveQueue.then(() => this.#send(scheme))
    return this.#saveQueue
  }

  async #send(scheme) {
    try {
      const response = await patch(this.urlValue, {
        body: JSON.stringify({ color_scheme: scheme }),
        contentType: "application/json",
        responseKind: "json"
      })
      return response.ok
    } catch {
      return false
    }
  }

  #current() {
    return this.optionTargets.find((option) => option.getAttribute("aria-checked") === "true")?.dataset
      .colorSchemeSchemeParam
  }

  #apply(scheme) {
    const root = document.documentElement
    if (scheme === "auto") delete root.dataset.scheme
    else root.dataset.scheme = scheme

    this.optionTargets.forEach((option) => {
      option.setAttribute("aria-checked", option.dataset.colorSchemeSchemeParam === scheme)
    })
    this.#paintBrowserChrome(scheme)
    this.#trackAppearance()
  }

  // The layout's tracked appearance meta must match the next page, or that visit reloads
  #trackAppearance() {
    const { theme, scheme } = document.documentElement.dataset
    const meta = document.querySelector("meta[name='html-appearance']")
    if (meta) meta.content = [theme, scheme].filter(Boolean).join(" ")
  }

  // Mirrors the layout: one tag for a chosen scheme, a media pair for Auto
  #paintBrowserChrome(scheme) {
    document.querySelectorAll("meta[name='theme-color']").forEach((meta) => meta.remove())
    const tags = scheme === "auto"
      ? [["light", "(prefers-color-scheme: light)"], ["dark", "(prefers-color-scheme: dark)"]]
      : [[scheme, null]]
    tags.forEach(([tone, media]) => {
      const meta = document.createElement("meta")
      meta.name = "theme-color"
      meta.content = tone === "dark" ? this.darkColorValue : this.lightColorValue
      if (media) meta.media = media
      document.head.append(meta)
    })
  }
}

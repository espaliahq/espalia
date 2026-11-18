/**
 * Lights every element sharing a `data-capability-map-key` while one is pointed at or focused,
 * and reloads the map's content frame at another `zoom`, tab or compared level.
 *
 * @example
 * <div data-controller="capability-map"
 *      data-action="mouseover->capability-map#light mouseout->capability-map#dim
 *                   focusin->capability-map#light focusout->capability-map#dim">
 *   <a data-capability-map-key="3">spoke</a>
 *   <a data-capability-map-key="3">lane</a>
 * </div>
 */

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["view"]

  #hovered = null
  #focused = null
  #keepComparing = (event) => this.#refetchComparison(event)

  connect() {
    super.connect()
    document.addEventListener("turbo:before-stream-render", this.#keepComparing)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.#keepComparing)
    super.disconnect()
  }

  zoom({ params: { zoom } }) {
    this.#reload({ zoom })
  }

  /** Switches tab, or the level the comparison tab compares with. */
  show({ params: { tab, compareLevel } }) {
    this.#reload({ tab, compare_level: compareLevel ?? null })
  }

  /** Moves focus along the tab list; Enter or Space then opens the focused tab. */
  moveTab(event) {
    const tabs = [ ...this.element.querySelectorAll("[role='tab']") ]
    const at = tabs.indexOf(event.currentTarget)
    const to = { ArrowRight: at + 1, ArrowLeft: at - 1, Home: 0, End: tabs.length - 1 }[event.key]
    if (to === undefined) return

    event.preventDefault()
    tabs[(to + tabs.length) % tabs.length].focus()
  }

  viewTargetConnected(view) {
    const { zoom, tab, compareLevel } = view.dataset
    this.#keep({ zoom: zoom ?? null, tab: tab ?? null, compare_level: compareLevel ?? null })
  }

  light(event) {
    this.#track(event, true)
  }

  dim(event) {
    this.#track(event, false)
  }

  #reload(changes) {
    const frame = this.#keep(changes)
    if (frame) this.#load(frame)
  }

  /**
   * A rating streams in the capabilities view, which would replace an open comparison. While the
   * comparison shows, or is loading, reload it instead, so it keeps its level and picks up the new score.
   */
  #refetchComparison(event) {
    const frame = this.element.querySelector("turbo-frame[data-reload-src]")
    if (!frame || event.target.getAttribute("target") !== frame.id) return
    if (new URL(frame.dataset.reloadSrc, window.location.origin).searchParams.get("tab") !== "compare") return

    event.detail.render = () => this.#load(frame)
  }

  /** Turbo fetches only when `src` changes, so the same source again needs `reload()`. */
  #load(frame) {
    const src = new URL(frame.dataset.reloadSrc, window.location.origin).href
    const current = frame.getAttribute("src")
    if (current && new URL(current, window.location.origin).href === src) frame.reload()
    else frame.src = src
  }

  /**
   * Writes the view into the content frame's reload source, so a reload after someone else's rating keeps it.
   * A null value drops that parameter.
   */
  #keep(changes) {
    const frame = this.element.querySelector("turbo-frame[data-reload-src]")
    if (!frame) return null

    const url = new URL(frame.dataset.reloadSrc, window.location.origin)
    Object.entries(changes).forEach(([ key, value ]) => {
      if (value === null || value === undefined) url.searchParams.delete(key)
      else url.searchParams.set(key, value)
    })
    frame.dataset.reloadSrc = `${url.pathname}${url.search}`
    return frame
  }

  /** Hover and focus are tracked apart, so the pointer leaving a focused spoke keeps it lit. */
  #track(event, on) {
    const key = event.target.closest?.("[data-capability-map-key]")?.dataset.capabilityMapKey
    if (!key) return

    const value = on ? key : null
    if (event.type.startsWith("focus")) this.#focused = value
    else this.#hovered = value

    this.element.querySelectorAll("[data-capability-map-key]").forEach((el) => {
      const hot = [ this.#hovered, this.#focused ].includes(el.dataset.capabilityMapKey)
      if (hot) el.dataset.hot = "true"
      else delete el.dataset.hot
    })
  }
}

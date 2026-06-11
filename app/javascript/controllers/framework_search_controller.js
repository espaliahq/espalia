// Free-text filter for the Framework Explorer matrix.
//
// Lives on the search box in the explorer header. Debounces keystrokes and
// dispatches a window-scoped `framework-search:changed` event carrying the
// trimmed query; `matrix_controller#updateSearch` merges it with the current
// role/track scope and re-fetches the matrix Turbo Frame. Esc and the inline
// × clear the field (immediate, no debounce).
//
// <div data-controller="framework-search">
//   <input data-framework-search-target="input"
//          data-action="input->framework-search#onInput keydown->framework-search#onKeydown">
//   <button data-framework-search-target="clear"
//           data-action="framework-search#clear">×</button>
// </div>

import BaseController from "controllers/base_controller"
import { useDebounce } from "stimulus-use"

export default class extends BaseController {
  static targets = ["input", "clear"]
  static debounces = ["emit"]

  connect() {
    super.connect()
    useDebounce(this, { wait: 250 })
  }

  // Keystroke handler — toggles the clear affordance immediately, emits
  // (debounced) so we re-fetch the matrix at most once per settle window.
  onInput() {
    this.#toggleClear()
    this.emit()
  }

  onKeydown(event) {
    if (event.key === "Escape" && this.inputTarget.value !== "") {
      event.preventDefault()
      this.clear()
    }
  }

  clear() {
    this.inputTarget.value = ""
    this.#toggleClear()
    this.inputTarget.focus()
    this.#dispatch() // immediate — clearing shouldn't wait out the debounce
  }

  // Debounced (see static debounces).
  emit() {
    this.#dispatch()
  }

  // private

  #dispatch() {
    window.dispatchEvent(new CustomEvent("framework-search:changed", {
      detail: { query: this.inputTarget.value.trim() }
    }))
  }

  #toggleClear() {
    if (this.hasClearTarget) {
      this.clearTarget.classList.toggle("hidden", this.inputTarget.value.length === 0)
    }
  }
}

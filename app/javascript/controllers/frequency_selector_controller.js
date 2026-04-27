// Optimistic UI for the self-assessment frequency selector.
//
// Highlights the clicked button immediately before the Turbo Stream
// response arrives with the authoritative state.
//
// <div data-controller="frequency-selector">
//   <button data-frequency-selector-target="button"
//           data-action="frequency-selector#select"
//           title="Some times" aria-label="Some times">Some</button>
//   <button data-frequency-selector-target="button"
//           data-action="frequency-selector#select"
//           title="Most times" aria-label="Most times">Most</button>
//   <button data-frequency-selector-target="button"
//           data-action="frequency-selector#select"
//           title="Consistently" aria-label="Consistently">Consistently</button>
// </div>

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]

  select(event) {
    // Remove active styling from all buttons
    this.buttonTargets.forEach(btn => {
      btn.classList.remove(
        "ring-1",
        "bg-amber-100", "dark:bg-amber-900/30", "text-amber-800", "dark:text-amber-300", "ring-amber-300", "dark:ring-amber-700",
        "bg-blue-100", "dark:bg-blue-900/30", "text-blue-800", "dark:text-blue-300", "ring-blue-300", "dark:ring-blue-700",
        "bg-green-100", "dark:bg-green-900/30", "text-green-800", "dark:text-green-300", "ring-green-300", "dark:ring-green-700"
      )
      btn.classList.add("text-gray-500", "dark:text-gray-400")
    })

    // Add a subtle highlight to the clicked button
    const btn = event.currentTarget
    btn.classList.remove("text-gray-500", "dark:text-gray-400")
    btn.classList.add("ring-1", "ring-gray-400", "text-gray-900", "dark:text-white")
  }
}

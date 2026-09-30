// Keeps the lens modal's level select in step with its role select: on a
// role change, the level options become that role's levels, keeping the
// ordinal the reader had picked when the new role has it (else the nearest).
//
// Usage:
//   <form data-controller="lens-picker" data-lens-picker-levels-value='{"<role_id>":[[1,"PM1 · …"],…]}'>
//     <select data-lens-picker-target="role" data-action="change->lens-picker#roleChanged">…</select>
//     <select data-lens-picker-target="level">…</select>
//   </form>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static targets = ["role", "level"]
  static values = { levels: Object }

  roleChanged() {
    const levels = this.levelsValue[this.roleTarget.value] || []
    const wanted = Number(this.levelTarget.value)
    const keep = this.#nearest(levels.map(([ordinal]) => ordinal), wanted)

    this.levelTarget.replaceChildren(
      ...levels.map(([ordinal, label]) => {
        const option = document.createElement("option")
        option.value = ordinal
        option.textContent = label
        option.selected = ordinal === keep
        return option
      })
    )
  }

  // private

  // Ties go to the lower level, matching Assessments::Lens.
  #nearest(ordinals, wanted) {
    return ordinals.reduce((best, ordinal) => {
      if (best === undefined) return ordinal
      const diff = Math.abs(ordinal - wanted) - Math.abs(best - wanted)
      return diff < 0 || (diff === 0 && ordinal < best) ? ordinal : best
    }, undefined)
  }
}

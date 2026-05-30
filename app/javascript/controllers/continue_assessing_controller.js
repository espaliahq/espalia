// Continue Assessing button inside the sticky hero summary.
//
// The hero lives inside the `assessment-scoring` turbo frame, which sits
// outside the matrix controller's element scope. Stimulus actions only
// fire on controllers that ENCLOSE the action element, so a direct
// `click->matrix#...` can't reach the matrix controller from here.
//
// Instead, dispatch a window event the matrix controller listens for.
//
// <a data-controller="continue-assessing"
//    data-action="click->continue-assessing#focus"
//    data-continue-assessing-capability-stable-id-value="<stable_id>"
//    data-continue-assessing-level-ordinal-value="<ordinal>">Continue assessing</a>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static values = {
    capabilityStableId: String,
    levelOrdinal: Number
  }

  focus(event) {
    event.preventDefault()
    window.dispatchEvent(new CustomEvent("assessment:focus-unrated", {
      detail: {
        capabilityStableId: this.capabilityStableIdValue,
        levelOrdinal: this.levelOrdinalValue
      }
    }))
  }
}

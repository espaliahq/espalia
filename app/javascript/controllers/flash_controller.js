// Auto-dismisses flash notice/alert toasts after a delay, and supports a
// click-to-dismiss close button.
//
// Usage:
//   <div data-controller="flash" data-flash-delay-value="5000">
//     <span>...message...</span>
//     <button data-action="flash#dismiss" aria-label="Dismiss">×</button>
//   </div>

import BaseController from "controllers/base_controller"
import { useTransition } from "stimulus-use"

export default class extends BaseController {
  static values = {
    delay: { type: Number, default: 5000 }
  }

  connect() {
    super.connect()
    useTransition(this, {
      element: this.element,
      enterActive: "transition-opacity duration-200",
      enterFrom: "opacity-0",
      enterTo: "opacity-100",
      leaveActive: "transition-opacity duration-300",
      leaveFrom: "opacity-100",
      leaveTo: "opacity-0",
      transitioned: true
    })

    if (this.delayValue > 0) {
      this._timer = setTimeout(() => this.dismiss(), this.delayValue)
    }
  }

  disconnect() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
    super.disconnect()
  }

  dismiss() {
    if (this._timer) {
      clearTimeout(this._timer)
      this._timer = null
    }
    this.leave().then(() => this.element.remove())
  }
}

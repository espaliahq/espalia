// Base controller that all application Stimulus controllers should extend.
//
// Automatically sets a data-connected attribute on the controller element
// when Stimulus connects, providing a reliable readiness signal for system
// tests. Without this, Capybara can interact with elements before Stimulus
// has attached action handlers — causing flaky tests on slow CI runners.
//
// Usage:
//   import BaseController from "controllers/base_controller"
//   export default class extends BaseController { ... }

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    super.connect()
    this.element.dataset.connected = ""
  }

  disconnect() {
    delete this.element.dataset.connected
    super.disconnect()
  }
}

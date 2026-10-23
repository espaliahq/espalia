# JavaScript and Stimulus Controller Standards

## Requirements

- Use ES6 syntax (arrow functions, destructuring, etc.)
- Extend `BaseController` (`controllers/base_controller`), not Stimulus's `Controller`. It marks the element `data-connected`, which the system tests' `wait_for_stimulus` waits for.
- Add usage comment at the top of every Stimulus controller
- Define `static targets`, `static values`, `static classes` at the top of the class
- Use `connect()` for initialization, `disconnect()` for cleanup
- Prefer toggling CSS classes over direct DOM manipulation
- Hide an element with its `hidden` attribute (`el.hidden = true`), not a `hidden` class. Tailwind's base styles hide `[hidden]` with `!important`, while a `.hidden` class ties with the element's own `flex` or `grid` class and loses on source order
- Use `stimulus-use` composable behaviors for common interaction patterns (see below)
- Keep controller actions focused on a single responsibility

## Server Requests (NON-NEGOTIABLE)

**Always use `@rails/request.js`** — never use raw `fetch()` with manual CSRF handling.

```javascript
// WRONG - fragile, breaks in test/devcontainer environments
fetch("/endpoint", {
  method: "PATCH",
  body: JSON.stringify({ key: value }),
  headers: {
    "X-CSRF-Token": document.querySelector("[name='csrf-token']").content,
    "Content-Type": "application/json"
  }
})

// CORRECT - handles CSRF, cookies, and headers automatically
import { patch } from "@rails/request.js"

const response = await patch("/endpoint", {
  body: JSON.stringify({ key: value }),
  contentType: "application/json"
})
```

Available methods: `get`, `post`, `put`, `patch`, `destroy` from `@rails/request.js`.

## Stimulus Controller Pattern

```javascript
// Example usage:
// <div data-controller="tooltip"
//      data-tooltip-content-value="Hello world"
//      data-tooltip-placement-value="top"></div>

import BaseController from "controllers/base_controller"

export default class extends BaseController {
  static values = {
    content: String,
    placement: { type: String, default: "top" },
    offset: { type: Number, default: 6 }
  }

  connect() {
    super.connect()
    this.setup()
  }

  disconnect() {
    this.cleanup()
    super.disconnect()
  }

  // private

  setup() {
    // initialization logic
  }

  cleanup() {
    // teardown logic
  }
}
```

## stimulus-use Composable Behaviors (NON-NEGOTIABLE)

**Prefer `stimulus-use` behaviors over writing custom interaction logic.** Only write custom Stimulus code for app-specific behavior that `stimulus-use` doesn't cover.

Common behaviors:
- `useClickOutside` — close dropdowns/modals on outside click
- `useTransition` — animated show/hide with CSS transition classes
- `useDebounce` / `useThrottle` — rate-limit actions
- `useIntersection` — lazy loading / infinite scroll
- `useHover` — hover interactions

```javascript
import { Controller } from "@hotwired/stimulus"
import { useClickOutside, useTransition } from "stimulus-use"

export default class extends Controller {
  static targets = ["menu"]

  connect() {
    useClickOutside(this)
    useTransition(this, { element: this.menuTarget })
  }

  toggle() {
    this.toggleTransition()
  }

  clickOutside() {
    this.leave()
  }
}
```

## Anti-patterns

```javascript
// Bad - var, anonymous functions, no disconnect cleanup, manual CSRF
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    var self = this
    this.element.addEventListener("click", function() {
      fetch("/endpoint", {
        headers: { "X-CSRF-Token": document.querySelector("[name='csrf-token']").content }
      })
    })
    // no disconnect() to clean up listener
  }
}
```

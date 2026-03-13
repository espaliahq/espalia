# JavaScript and Stimulus Controller Standards

## Requirements

- Use ES6 syntax (arrow functions, destructuring, etc.)
- Add usage comment at the top of every Stimulus controller
- Define `static targets`, `static values`, `static classes` at the top of the class
- Use `connect()` for initialization, `disconnect()` for cleanup
- Prefer toggling CSS classes over direct DOM manipulation
- Use `tailwindcss-stimulus-components` for common UI (Alert, Dropdown, Modal, Tabs, Popover, Toggle, Slideover)
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

import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    content: String,
    placement: { type: String, default: "top" },
    offset: { type: Number, default: 6 }
  }

  connect() {
    this.setup()
  }

  disconnect() {
    this.cleanup()
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

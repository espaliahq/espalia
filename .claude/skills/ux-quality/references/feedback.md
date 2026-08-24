# Feedback — acknowledgment, optimistic UI, toasts, destructive actions, microcopy

## Control states

- Every interactive control has visibly distinct default, hover, active,
  focus-visible, disabled, and (where applicable) loading states. Drive
  hover and keyboard focus separately and screenshot both.
- **Severity 3: no visible keyboard focus indicator** — a failed WCAG 2.4.7
  (AA) success criterion, rated per SKILL.md's scale.
- Affordances exist: cursor changes on interactive elements, pressed
  states respond, disabled states are visually distinct.

## Every action acknowledges

- Within 1s of any mutation there is visible evidence it happened — the
  item appears or updates in place, an inline confirmation, or a status
  message. Silent success is a defect: make the change, then verify the UI
  reflects it without a manual refresh.
- Flows end with closure: an explicit completion signal and a "what next",
  not a silent redirect.

## Optimistic vs pessimistic updates

- Optimistic is fine for low-stakes, reversible, likely-to-succeed actions
  (toggles, reorders, likes).
- Pessimistic (wait for the server) is required for payments, deletes
  without undo, and anything the server may reject.
- Adversarial test: apply the optimistic action against a 500 — the UI
  must roll back visibly and tell the user.
  **Blocker: failed mutation leaves the UI showing success.**

## Toasts and snackbars

Acceptable only for low-stakes, redundant confirmation. Defects:

- A toast is the only evidence of an error or a destructive outcome.
- The only path to an action (Undo) lives in a toast that auto-dismisses
  in under ~6s.
- Toast text is not announced (`role="status"`/`aria-live="polite"` for
  info, `role="alert"` for errors) — and the live region must exist before
  the message is injected (see accessibility.md).
- Toasts cover content or stack unboundedly — fire the action five times.

Inline confirmation near the point of action beats a toast; a visible
state change in the page beats both.

## Destructive actions — undo over confirm

- Prefer undo with a grace period: confirmation dialogs get dismissed on
  autopilot and stop preventing errors.
- If confirmation is used: the dialog names the object ("Delete 'Q3
  report'?" — never "Are you sure?"), the confirm button states the action
  ("Delete", not "OK"/"Yes"), the destructive button is not the
  default-focused primary, and Escape/backdrop-click cancels.
- Test: trigger delete and press Enter immediately — default focus must
  not destroy data.
- Bulk or irreversible operations: type-to-confirm or undo-with-grace.
- Destructive actions are visually separated from safe ones.

## Microcopy

- Buttons are specific verb + object ("Save changes", "Delete invoice") —
  not "Submit", "OK", "Yes", "Click here". Confirm-dialog buttons are
  answerable without reading the body ("Delete" / "Keep editing").
- One casing convention (sentence or title case) held across all buttons
  and headings — inventory a screen and flag mixing. The defect is
  inconsistency, not the choice.
- One name per concept everywhere; a nav label matches its page title.
- Copy is reviewed against the host's voice guide and customer
  vocabulary where discovery found one: product nouns match how the host
  names its users and domain objects (the product's word for its
  customers, not the API's). Neither input discovered → check internal
  consistency only.
- No system jargon or raw enums in rendered text — scan for
  `_`-separated uppercase tokens, `undefined`, `null`, `NaN`.
  `undefined`/`NaN` rendered to users is always a defect — rate it on
  SKILL.md's scale by its actual task impact.
- Instructional text is front-loaded and scannable; empty states and
  errors follow the same verb-first plain language.

# Mode: build — defaults that make the review find nothing

Read the references as **constraints while writing UI code**. Everything
here is checked adversarially at assess time; building to it is cheaper
than fixing it.

## Before writing

- Run discovery (per SKILL.md). Use the host's design system components —
  reuse over reinvention; a lookalike with different padding is a review
  finding.
- Identify the five states for every screen you're about to build
  (`references/states.md`). If the spec doesn't define one, get it
  defined or flag the invention you're making — don't silently guess.

## Defaults while building

**Structure and semantics** (`references/accessibility.md`)

- Native elements first: `button`, `a`, `input`, `select`, `dialog`.
  A custom widget takes the full APG contract (role, name, tabindex,
  Enter and Space, state attributes that update) — budget for it or
  don't build custom.
- No ARIA is better than bad ARIA. Add it to fix a real gap, not as
  seasoning.
- Heading levels follow document structure; landmarks over div soup;
  `lang` on the document; `document.title` and focus managed on route
  change.

**States** (`references/states.md`)

- Empty states instruct and offer the next action. Skeletons match the
  loaded layout and reserve its space. Indicators appear past 1s,
  determinate progress plus cancel past 10s. Errors get retry
  affordances. Refetch keeps stale content visible.

**Forms** (`references/forms.md`)

- Visible associated labels (never placeholder-as-label); required and
  optional marked; validate on blur/submit, never mid-first-entry; clear
  errors as soon as input becomes valid; failed submit preserves values;
  error summary focuses on multi-error submit; correct
  `type`/`inputmode`/`autocomplete`; never block paste; disable-during-
  in-flight on submit so double-clicks send one request.

**Feedback** (`references/feedback.md`)

- Every mutation visibly acknowledges within 1s. Optimistic updates roll
  back visibly on failure. Toasts only for redundant confirmation, in a
  pre-existing live region. Destructive actions: undo over confirm;
  confirmations name the object and the action verb.

**Navigation** (`references/navigation.md`)

- Shareable state (filters, tabs, pagination, detail) lives in the URL
  and survives refresh and Back. Dirty forms intercept navigation.
  `aria-current` on the active nav item.

**Visual** (`references/visual.md`)

- Sizes, spacing, and colors from the host's tokens — no ad-hoc values.
  Focus rings visible and unclipped. Reserve dimensions for async
  content so nothing shifts. Test target sizes against WCAG 2.5.8 as you
  build — 24×24, with its spacing/equivalent/inline exceptions
  (`references/accessibility.md`).

## Self-check before handoff or PR

The two-minute version of the assess mode; run it on your own work:

1. Keyboard-only through the whole flow — reachable, visible focus, no
   traps, Escape closes what it should.
2. Force empty and error states once each — designed, with a way
   forward?
3. 320px viewport and 200% zoom — no horizontal scroll, nothing clipped.
4. Paste a 200-character name and a long unbroken string — layout holds?
5. Double-click every submit — one request?
6. Console clean across the whole flow — zero errors, no new warnings?
7. axe run on the finished screens (`references/tooling.md`) — zero
   violations, `incomplete` triaged.

Anything you deviated from deliberately: record it where your team
records decisions, labeled as UX debt — the assess mode will find it
otherwise.

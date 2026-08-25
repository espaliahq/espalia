# Navigation — wayfinding, Back, deep links, unsaved changes

## Wayfinding

- The active nav link or wizard step is visually distinct and carries
  `aria-current` (`page` / `step`). ARIA tabs are different: a `tablist`'s
  active tab carries `aria-selected="true"`, never `aria-current`.
- Current location also shows in the page title and `document.title`
  (which must update on SPA route change — WCAG 2.4.2).
- Breadcrumbs on hierarchies two or more levels deep: ancestors clickable,
  current page not a link.
- More than one way to reach a page — nav plus search, index, or links
  (WCAG 2.4.5; sequential process steps exempt).

## The Back button

Test after every kind of in-app navigation — page changes, modals-as-
routes, tab switches that claim URL state, pagination, filtering:

- Back returns to the previous view with its state intact — it never exits
  the app, re-submits a mutation, or lands on a broken state. Forward
  works too. **Blocker: Back exits the SPA or breaks the page.**
- Scroll position is sane after Back (restored on return to a list;
  reset on entry to a new view).

## Deep links and URL state

- Copy the URL from any meaningful state — detail page, filtered list,
  active tab, a legitimate mid-wizard step — and open it in a fresh tab:
  it reconstructs the state or redirects somewhere sensible.
  **Blocker: hard refresh 404s or white-screens.**
- Filter, search, sort, and pagination state users would share or
  bookmark belongs in the URL and survives refresh.
- Guarded routes redirect to sign-in and return to the target after.

## Unsaved changes

- With a dirty form, an in-app navigation triggers an interception dialog
  (stay / discard); closing the tab fires `beforeunload` for substantial
  input. No interception on either path is a data-loss defect.
- `beforeunload` is a best-effort supplement, not the recovery mechanism:
  mobile browsers often skip it, and a standing listener costs
  back/forward-cache eligibility — attach it only while dirty, and prefer
  app-level draft persistence for work worth keeping.
- Warning when the form is clean is also a defect.
- After an interruption the app recovers the user's work and place
  wherever feasible (protect users' work).

## Session and state

- Session expiry mid-form does not eat the form: submitting after expiry
  preserves input through re-authentication, or warns before expiry.
- Where the product remembers state across sessions (drafts, filters,
  last location), returning users land where they left off.

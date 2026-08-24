# States — the five states, loading, errors, resilience

Every screen and every data-bearing component has five states: ideal,
empty, loading, partial, error. Defects live in the four nobody designed.
Verify each by forcing it — block or delay the API route, return `[]`,
return one item, return 500 — never by hoping to stumble on it.

## Empty

- Zero records shows a purposeful empty state — a short status plus a
  pathway to the key action ("No orders yet — create your first order") —
  never a blank panel, `undefined`, an orphaned table header, or an eternal
  spinner. **Blocker: blank screen on empty data.**
- Empty search results and empty filter results are distinct from
  first-run empty, and say how to broaden.

## Loading

Response-time thresholds (NN/g):

| Delay             | Requirement                                                                                          |
| ----------------- | ---------------------------------------------------------------------------------------------------- |
| < 0.1s            | No indicator — one would flicker                                                                     |
| 0.1–1s            | May pause without an indicator, but must not silently block input                                    |
| > 1s              | Visible busy indicator required. **Blocker if absent.**                                              |
| > 10s, measurable | Determinate progress (percent or time remaining) plus cancel                                         |
| Unbounded         | Honest indeterminate status naming the current activity, plus cancel — never a fabricated percentage |

- Skeletons for content-shaped loads (lists, cards, dashboards); spinners
  for short blocking actions (submit, save); progress bars past 10s.
- A skeleton must match the loaded layout — content jumping on resolve is a
  defect. Skeletons and spinners reserve the space of what they replace.
- Fast responses must not flash a sub-100ms spinner: delay or
  minimum-duration the indicator.
- Throttle the network and click things mid-load: the app must not wedge.
- On refetch, existing content stays visible (dimmed or inline indicator)
  rather than unmounting to a full-page spinner.

## Partial

- One item still looks intentional: no "showing 1 of 1", no pagination for
  one page, no stretched lone card.
- Records missing optional fields (null avatar, no description) degrade
  gracefully.

## Error

- Every failure surface shows a designed error state with a retry
  affordance that actually refires the request — never a blank region, a
  stuck skeleton, an infinite spinner, or a raw exception.
- A crashed component shows a designed error boundary: plain-language
  explanation, retry or home link. **Blocker: white screen of death.**
- Unhandled promise rejections in the console during a failure are defects
  even when the UI looks fine.
- Offline: an explicit "you appear to be offline"-style message, and
  recovery on reconnect (automatic or one retry click).
- Partial degradation: fail one endpoint of several — only that panel
  degrades. One failed widget must not take down the page.
- 404 and permission-denied are distinct, designed pages with a way back.
- Error copy never blames the user, never leads with codes or jargon
  (a reference code as secondary detail is fine), always says what to do
  next. It distinguishes "your input is wrong" from "the service failed".

## Ideal-but-extreme — adversarial data injection

Inject before judging layout:

- 200-character names; unbroken strings (`WWWW…`, long URLs, long emails).
- Zero, negative, and huge numbers; empty strings; whitespace-padded input.
- German-length words (translations run 30–40% longer); RTL text; emoji.
- 10k-row lists; deep pagination.

Assertions: text wraps or truncates deliberately (ellipsis plus the full
value reachable via tooltip or detail); truncation never hides the
distinguishing part of a value (two items must not truncate identically);
nothing paints over neighbours; blocked images produce alt text,
dimensioned placeholders, or designed fallbacks — never broken-image icons
or layout shift.

## Interruption and concurrency sweep

Run against every flow under review:

- Double-click every submit; click during in-flight requests.
- Hammer browser Back/Forward; refresh mid-flow; deep-link into mid-flow
  URLs.
- Edit the same record in two tabs.
- Resize to 320px and ultrawide; zoom to 200%.
- Leave a form idle past session expiry, then submit.
- After every interruption, assert the user's work and place are preserved
  (protect users' work — a hard assertion, not a preference).

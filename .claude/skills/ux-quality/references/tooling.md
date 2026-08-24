# Tooling — measurement recipes for browser-driven review

The one rule: **screenshots for overall composition, script evaluation for anything
numeric.** Screenshot review reliably catches broken layout, collisions,
truncation, gross misalignment, wrong theme surfaces. It reliably misses
1–2px offsets, exact colors, radius/shadow deltas, hover/focus states, and
below-the-fold content. Never assert "spacing is 16px" from pixels — read
the computed style. The inverse holds too: for _is it actually painted_
questions (scrims, overlays, indicators), the screenshot outranks computed
styles — a backdrop can compute `black/50%` and paint nothing.

These recipes are written against capabilities, not one tool's function
names: navigate, screenshot, evaluate JS, emulate viewport/media, read
console/network. Map them onto whatever automation discovery found.

## axe-core injection

- Locate `axe.min.js`: the host's `node_modules/axe-core/axe.min.js`
  first, else `scripts/fetch-axe.sh` downloads a pinned copy to a cache.
  Inject its source via script evaluation (bypasses the page's script-src
  CSP); guard with `if (!window.axe)`.
- No curl egress in the agent's sandbox? Fall back to fetching the same
  pinned version from inside the page (`axe-core@<AXE_VERSION>` from the
  CDN via in-page `fetch`), with the same `if (!window.axe)` guard — the
  browser often has the egress the shell lacks.
- WCAG 2.2 AA tag set below; a separate run may add `best-practice`
  (landmarks, heading order) — label those findings as best-practice, never
  as WCAG failures:

```js
await axe.run(document, {
  runOnly: {
    type: 'tag',
    values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa'],
  },
})
```

- Read `violations` (each has `impact` minor/moderate/serious/critical,
  node selectors, `failureSummary`) **and** `incomplete` — the manual
  review queue. Impact is evidence for the rating, not the rating itself —
  severity comes from SKILL.md's frequency × impact × persistence.
- **Run per state, not per page:** after opening the modal, after
  triggering the error state, in dark mode. axe only sees the current DOM.

## Emulation matrix

- **Viewports:** 320 (reflow floor), 375, 768 (breakpoint seams),
  1280–1440. Probe ±1px around the host's breakpoints — boundaries are
  where layouts break.
- **Network/CPU throttling:** reveals missing loading states, layout
  pop-in, race conditions, jank (4× CPU ≈ low-end mobile). Reapply after
  navigation — throttling doesn't always survive it.
- **Media emulation:** `prefers-color-scheme` both ways;
  `prefers-reduced-motion: reduce` (assert animations actually stop);
  `forced-colors: active` (Windows High Contrast survival). Vision-
  deficiency emulation (deuteranopia etc.) where available, for the
  "not color alone" checks; a grayscale screenshot is the fallback.
- **Zoom:** 200% (WCAG 1.4.4) is a zoom test — use real browser zoom or
  text scaling where the driver supports it; halving the viewport only
  approximates page zoom and misses text-only resize. Reflow stays its own
  check: 400% at 1280px ≡ the 320px viewport test.

## Script-evaluation measurements

The deterministic visual checks run as **one batch, not piecemeal probes**:
inject `scripts/audit-page.js` and call `__uxAudit({spacingScale,
fontScale, minTarget})` with the scales discovery found — per state and
per viewport, like axe. It returns tallies and capped examples for font
sizes, off-scale spacing, sub-minimum targets, overflow, radii, and
duplicate ids. Without a discovered spacing or font scale it tallies
values but classifies nothing off-scale — read the spread as
internal-consistency evidence, never as token violations. Its output is
evidence: the 2.5.8 exceptions and every severity call stay with the
reviewer. Ad-hoc evaluation remains for what
the batch doesn't cover:

- `getComputedStyle` — token conformance: font sizes, spacing values,
  colors resolve to the host's scale.
- `getBoundingClientRect` — alignment (shared x-coordinates), overlap,
  target size (≥24×24, then apply the exceptions).
- `document.documentElement.scrollWidth > clientWidth` — horizontal
  overflow at 320px.
- Focus-order trace: send Tab/Shift+Tab through the driver's key input —
  trusted events; a synthetic dispatched `KeyboardEvent` does not move
  focus. Script evaluation only records `document.activeElement`
  (selector + rect) at each stop.
- Obscured focus (2.4.11): at each focus stop, run
  `document.elementsFromPoint()` at representative points inside the
  focused element — any author content can obscure, not just
  `fixed`/`sticky` chrome, so rect intersection with those is only a
  cheap prefilter. Paint order, opacity and `pointer-events` all matter;
  fail only when author content hides the element _entirely_, and send
  ambiguous cases to manual review.
- Focus visibility (2.4.7): screenshot the element unfocused, focus it,
  screenshot again — identical pixels mean no indicator. Sample indicator
  vs background pixels for the 3:1 check (1.4.11).
- Text spacing (1.4.12): inject a style tag with the four `!important`
  overrides; `scrollHeight > clientHeight` on `overflow: hidden` text
  containers is a cheap clipping detector; screenshot for overlap.
- Accessibility tree (however the tooling exposes it — many snapshot
  tools derive from it): ground truth for name/role/state. A control
  missing from it is a control assistive tech can't reach. Diff before
  and after interactions to verify `expanded`/`checked` updates.
- Hidden-input widgets (zag/radix-style checkboxes and radios) expose a
  1×1 visually-hidden input to the accessibility tree — clicks aimed at
  that node time out. Click the visible label or styled control instead,
  or dispatch the pointer sequence at the visible proxy.

## Lighthouse (when available)

- Accessibility score is weighted pass/fail axe rules — a smoke signal;
  100 still isn't "accessible". Injected axe supersedes it.
- Performance thresholds, good/poor: **LCP** ≤2.5s / over 4s; **CLS**
  ≤0.1 / over 0.25; **INP** ≤200ms / over 500ms (field-only; lab uses TBT
  ≤200ms as proxy). CLS is the most directly design-relevant metric.
- Run mobile-throttled and desktop passes — 95 on desktop can be unusable
  on the mobile profile.

## Console and network as UX signals

- Any console error appearing **on interaction** signals a broken path
  even when the UI looks fine — swallowed rejections behind a silent
  button are classic. Framework warnings (keys, hydration,
  controlled-input flips) predict flicker and state bugs. A clean pass:
  zero errors, no new warnings across the whole interaction script.
- Network: 4xx/5xx the UI never surfaces (a failed save with no error
  message is severity-high); requests pending >1s with no loading state;
  duplicate identical requests on one interaction; oversized payloads;
  refetch-per-keystroke without debounce.

# Accessibility — WCAG 2.2 Level AA

Scope: WCAG 2.2, Levels A + AA — 55 success criteria (31 A, 24 AA).
**4.1.1 Parsing is removed in 2.2**: duplicate IDs are no longer a finding
in themselves — test them where they break something real: label and ARIA
associations (4.1.2), or fragment and skip-link targets. Do not demand AAA
(44×44 targets, 7:1 contrast, Focus Appearance metrics).

Test tags: **AUTO** — axe/Lighthouse catches reliably. **SEMI** — a tool
flags candidates, the reviewer confirms. **MANUAL** — needs interaction or
judgment.

## Check first — the WebAIM Million top six

96% of detectable errors on the top million home pages are six types.
Always check these before anything else:

1. Low-contrast text (83.9% of pages)
2. Missing image alt text (53.1%)
3. Missing form input labels (51%)
4. Empty links — icon links with no accessible name (46.3%)
5. Empty buttons (30.6%)
6. Missing document language (13.5%)

Pages using ARIA average _more_ errors than pages without (59 vs 42):
no ARIA is better than bad ARIA.

## Success criteria

### Perceivable

| SC          | Name (level)                   | Meaning                                                                             | Test                                              |
| ----------- | ------------------------------ | ----------------------------------------------------------------------------------- | ------------------------------------------------- |
| 1.1.1       | Non-text Content (A)           | Every image/icon has a text alternative; decorative hidden (`alt=""`/`aria-hidden`) | SEMI — axe finds missing alt; quality is judgment |
| 1.2.1–1.2.5 | Time-based media (A/AA)        | Transcripts; captions incl. live; audio description                                 | MANUAL (SEMI: detect `<track>`)                   |
| 1.3.1       | Info and Relationships (A)     | Visual structure (headings, lists, tables, labels, groups) exists programmatically  | SEMI                                              |
| 1.3.2       | Meaningful Sequence (A)        | DOM order matches reading order — beware CSS `order`, absolute positioning          | MANUAL                                            |
| 1.3.3       | Sensory Characteristics (A)    | Instructions never rely only on shape/color/position                                | MANUAL                                            |
| 1.3.4       | Orientation (AA)               | Portrait and landscape both work                                                    | SEMI                                              |
| 1.3.5       | Identify Input Purpose (AA)    | Correct `autocomplete` tokens on personal-data fields                               | AUTO/SEMI                                         |
| 1.4.1       | Use of Color (A)               | Color never the only cue — links in prose, errors, chart series                     | MANUAL — grayscale screenshot pass                |
| 1.4.2       | Audio Control (A)              | Autoplaying audio >3s pausable                                                      | MANUAL                                            |
| 1.4.3       | Contrast Minimum (AA)          | Text ≥4.5:1; large text ≥3:1                                                        | AUTO; text over images needs pixel checks         |
| 1.4.4       | Resize Text (AA)               | 200% zoom loses nothing                                                             | MANUAL                                            |
| 1.4.5       | Images of Text (AA)            | Real text, not pictures of it (logos exempt)                                        | MANUAL                                            |
| 1.4.10      | Reflow (AA)                    | 320 CSS px width, no 2-D scrolling (data tables/maps exempt)                        | SEMI                                              |
| 1.4.11      | Non-text Contrast (AA)         | Component boundaries, states, focus rings, meaningful graphics ≥3:1                 | MANUAL/SEMI — axe barely covers this              |
| 1.4.12      | Text Spacing (AA)              | Spacing overrides (below) break nothing                                             | SEMI — inject stylesheet, look for clipping       |
| 1.4.13      | Content on Hover or Focus (AA) | Tooltips dismissible (Esc), hoverable, persistent                                   | MANUAL                                            |

### Operable

| SC     | Name (level)                  | Meaning                                                   | Test                                                                    |
| ------ | ----------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------- |
| 2.1.1  | Keyboard (A)                  | Everything operable by keyboard alone                     | MANUAL                                                                  |
| 2.1.2  | No Keyboard Trap (A)          | Focus never stuck                                         | MANUAL                                                                  |
| 2.1.4  | Character Key Shortcuts (A)   | Single-char shortcuts remappable or focus-scoped          | MANUAL                                                                  |
| 2.2.1  | Timing Adjustable (A)         | Limits off / ≥10× / 20s-warned extension (20h exempt)     | MANUAL                                                                  |
| 2.2.2  | Pause, Stop, Hide (A)         | Auto-moving content >5s pausable                          | MANUAL                                                                  |
| 2.3.1  | Three Flashes (A)             | Nothing flashes >3×/s                                     | MANUAL/SEMI                                                             |
| 2.4.1  | Bypass Blocks (A)             | Skip link or landmarks                                    | AUTO presence; working is MANUAL                                        |
| 2.4.2  | Page Titled (A)               | Descriptive `document.title`, updated on SPA route change | SEMI                                                                    |
| 2.4.3  | Focus Order (A)               | Tab order preserves meaning                               | MANUAL                                                                  |
| 2.4.4  | Link Purpose (A)              | Link text says where it goes                              | SEMI                                                                    |
| 2.4.5  | Multiple Ways (AA)            | ≥2 ways to find pages                                     | MANUAL                                                                  |
| 2.4.6  | Headings and Labels (AA)      | Describe topic or purpose                                 | MANUAL                                                                  |
| 2.4.7  | Focus Visible (AA)            | Visible indicator on every focusable element              | MANUAL/SEMI — screenshot-diff                                           |
| 2.4.11 | Focus Not Obscured (AA, new)  | Focused element never entirely hidden by sticky chrome    | MANUAL — intersect rects                                                |
| 2.5.1  | Pointer Gestures (A)          | Multipoint/path gestures have single-pointer alternatives | MANUAL                                                                  |
| 2.5.2  | Pointer Cancellation (A)      | Actions fire on up-event                                  | MANUAL                                                                  |
| 2.5.3  | Label in Name (A)             | Accessible name contains the visible label                | SEMI — axe's only rule is experimental, off by default; verify manually |
| 2.5.4  | Motion Actuation (A)          | Shake/tilt has UI alternatives                            | MANUAL                                                                  |
| 2.5.7  | Dragging Movements (AA, new)  | Every drag has a non-drag alternative                     | MANUAL                                                                  |
| 2.5.8  | Target Size Minimum (AA, new) | Targets ≥24×24 CSS px, with exceptions                    | SEMI — measure, then judge exceptions                                   |

### Understandable

| SC    | Name (level)                                 | Meaning                                                             | Test   |
| ----- | -------------------------------------------- | ------------------------------------------------------------------- | ------ |
| 3.1.1 | Language of Page (A)                         | Valid `lang` on `<html>`                                            | AUTO   |
| 3.1.2 | Language of Parts (AA)                       | Foreign passages get their own `lang`                               | SEMI   |
| 3.2.1 | On Focus (A)                                 | Focus never triggers a context change                               | MANUAL |
| 3.2.2 | On Input (A)                                 | Changing a setting never auto-submits unwarned                      | MANUAL |
| 3.2.3 | Consistent Navigation (AA)                   | Repeated nav in the same order across pages                         | MANUAL |
| 3.2.4 | Consistent Identification (AA)               | Same function, same name/icon everywhere                            | MANUAL |
| 3.2.6 | Consistent Help (A, new)                     | Help mechanisms in the same relative place on every page            | MANUAL |
| 3.3.1 | Error Identification (A)                     | Errors in text; offending field named                               | MANUAL |
| 3.3.2 | Labels or Instructions (A)                   | Visible labels — placeholder alone fails                            | SEMI   |
| 3.3.3 | Error Suggestion (AA)                        | Messages suggest a fix when known                                   | MANUAL |
| 3.3.4 | Error Prevention — Legal/Financial/Data (AA) | Reversible, checked, or confirmable                                 | MANUAL |
| 3.3.7 | Redundant Entry (A, new)                     | One process never asks twice — auto-populate or offer selection     | MANUAL |
| 3.3.8 | Accessible Authentication (AA, new)          | No cognitive test to log in; never block paste or password managers | MANUAL |

### Robust

| SC    | Name (level)          | Meaning                                                     | Test                                        |
| ----- | --------------------- | ----------------------------------------------------------- | ------------------------------------------- |
| 4.1.2 | Name, Role, Value (A) | Every component exposes name, role, state; notifies changes | AUTO/SEMI — dynamic state needs interaction |
| 4.1.3 | Status Messages (AA)  | Toasts, counts, results announced without moving focus      | MANUAL — live region must pre-exist         |

## Numbers

- **Contrast:** normal text **4.5:1**; large text **3:1** (large = ≥18pt /
  24px regular, or ≥14pt / 18.66px bold); non-text (borders, icons, focus
  rings) **3:1**. Exempt: disabled controls, decoration, logos.
- **Target size:** **24×24 CSS px**. Exceptions: spacing (a 24px circle
  centred on the target intersects no other target or circle), an
  equivalent conforming control on the same page, inline-in-text,
  user-agent default, essential. 44pt (Apple) / 48dp (Material) are
  platform recommendations for primary controls — cite as such, not as
  WCAG.
- **Reflow:** **320 CSS px** width (= 400% zoom at 1280px), no
  two-dimensional scrolling; 256px height for horizontal content.
- **Text spacing overrides:** line-height **1.5×**, paragraph **2×**,
  letter **0.12em**, word **0.16em** — nothing clips or overlaps.
- **Other:** resize 200% · audio autoplay 3s · flashes ≤3/s · moving
  content pausable if >5s.

## Automated coverage — the honest limits

- Estimates, not measurements of your page: axe-core caught ~57% of
  issues **by volume** in Deque's 2021 study (~300k issues across 13k+
  pages); the long-standing industry estimate is that only ~20–30% of
  success criteria are fully automatable. Zero violations means "nothing
  detectable", never "accessible".
- axe's `incomplete` array (contrast over gradients, etc.) is the manual
  review queue — never discard it.
- Lighthouse's accessibility category is an axe-core subset; prefer full
  axe injection (see tooling.md).

## SPA pitfalls

- **Route changes are silent.** On client-side navigation:
  `document.title` updates and focus moves to the new view's heading or
  container. Test both after navigating.
- **Live regions must pre-exist** in the DOM before text is injected;
  toasts freshly rendered into a portal routinely fail 4.1.3. Inspect the
  DOM before triggering the toast.
- **Modals:** focus moves in on open; Tab wraps; the background is made
  inert (`inert` or equivalent focus containment — `aria-modal` only
  announces modality, it enforces nothing); Escape closes; focus returns
  to the trigger on close. Verify the background really is unreachable by
  Tab. Native `<dialog>.showModal()` provides containment for real.
- **`<div onClick>`** fails keyboard (2.1.1), name/role/value (4.1.2),
  often target size. First question for any interactive element: is it a
  native `button`/`a`/`input`? If custom: role, `tabindex="0"`, accessible
  name, Enter _and_ Space handlers, state attributes that actually update.
- **ARIA misuse:** `aria-hidden` on focusable content; an `aria-label`
  that drops the visible label text (2.5.3 requires the accessible name
  to _contain_ the visible label — adding context around it conforms);
  `role="menu"` on plain
  navigation (imposes an arrow-key contract nobody implemented);
  `aria-expanded` that never flips; role parent/child violations.
- **Endemic:** scroll not reset on route change; focus dropped to
  `<body>` when the focused element unmounts (deleted rows, closed
  panels) — it should move to a sensible neighbour; infinite scroll
  trapping keyboard users before the footer; skeletons never announcing
  completion.

## Keyboard procedure (APG contract)

1. **Tab sweep** through the whole page, recording `document.activeElement`
   at each stop: everything interactive reachable; order logical; nothing
   invisible or `aria-hidden` focusable; indicator visible at every stop;
   no traps; skip link first. Then **Shift+Tab** back.
2. **Enter** activates links and buttons; **Space** activates buttons and
   toggles checkboxes — and must not scroll the page while a button is
   focused.
3. **Escape** closes modals, menus, tooltips, comboboxes without losing
   focus context.
4. **Arrows inside composite widgets** (one Tab stop per widget): radio
   groups; tabs (Tab goes to the panel, not the next tab); menus (Esc
   returns focus to the trigger); listbox/combobox (`aria-expanded`,
   `aria-activedescendant` update); grid/tree (four arrows, Home/End);
   slider (arrows adjust, `aria-valuenow` updates).
5. **Dialog cycle:** open → focus inside → Tab wraps → Esc → focus back on
   the invoker.
6. **Red flags:** `tabindex > 0` anywhere; focus jumping to `<body>`;
   `outline: none` with no replacement; mouse-only event handlers.

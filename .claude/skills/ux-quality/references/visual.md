# Visual — typography, spacing, color, consistency, polish

Consistency criteria run against the host's design system found during
discovery. Without one, apply only the generic craft rules — do not invent
a system to enforce.

The deterministic checks in this file (off-scale spacing and sizes, small
targets, overflow, radius spread) run through `scripts/audit-page.js`:
inject once, then call `__uxAudit(...)` after **every** state and
viewport change — the injection guard survives, results come from the
call (see tooling.md). Judgment criteria stay judged.

## Typography

- Font sizes collapse to a small defined scale (5–8 sizes). A rogue
  13.5px, or a size used nowhere else in the app, is a defect.
- Hierarchy is carried by weight and color — two weights, two to three
  text colors — not size alone. Supporting text is de-emphasized; labels
  don't shout louder than values.
- Body line length 45–75 characters. Body line-height ≥1.5; headings
  1.1–1.3.
- Minimum sizes come from the host's type scale where one is discovered —
  some systems legitimately set body at 14px. Without a scale, the
  fallback heuristics are body ≥16px and interactive text ≥14px. WCAG
  sets no minimum font size; 200% resize (1.4.4) is the hard requirement.
  Thin weights only at display sizes.
- Muted text on a tinted background is a shade of the background hue, not
  grey with opacity.
- No orphan words in buttons or headings where avoidable; no mid-word
  truncation without ellipsis; tabular numerals where digits align in
  columns.

## Spacing and layout

- All spacing sits on the host's token scale. A computed value absent
  from that scale (a 13px margin on a 4/8px grid) is a defect — check
  computed styles, not pixels, and let rem/calc values that resolve to
  tokens pass. No discovered scale → check internal consistency only.
- Proximity encodes grouping: the label-to-its-field gap is smaller than
  the field-to-next-field gap; within-card spacing is smaller than
  between-card. Ambiguous "which heading owns this" spacing is a
  hierarchy bug.
- Proximity is judged by measurement, not by eye. When the host's design
  system names spacing semantics (which token goes within a group, which
  between), those are the oracle; without them, assert the ratio —
  measure that within-group gaps are smaller than between-group gaps.
- Elements sharing a visual column align to the same x-coordinate.
- One obvious primary action per view. A heavily blurred screenshot
  (squint test) still reveals the page structure and the primary CTA.
- Content isn't flush against container edges; sections breathe.

## Color

- Semantic colors used semantically: red only for destructive/error,
  green for success, the primary color for the primary action — a Delete
  button in the brand color is a defect.
- Computed colors resolve to the host's design tokens, not one-off hex
  values.
- 4.5:1 is a floor, not a target — secondary text that only just clears
  it on a tinted background reads washed-out. Check non-text 3:1 on input
  borders, icons, and focus rings.
- State is conveyed by more than color: error fields carry an icon or
  message; links in prose are distinguished beyond hue; chart series
  differ by more than color.
- Dark mode, where the host has one: every surface, border, shadow, and
  illustration has a dark value; elevation via lighter surfaces, not
  shadows alone; no light-mode cards leaking through.

## Consistency with the host system

- **Reuse over reinvention:** a new feature uses the host's existing
  Button/Input/Modal/Toast components. A hand-rolled lookalike with
  slightly different padding or radius is a finding even if it looks fine
  in isolation.
- Pattern matching: destructive confirmation, validation timing, toast vs
  inline, pagination style — resolved the way the rest of the app already
  resolves them.
- One icon family: same stroke weight, optical size, corner style; one
  icon per concept everywhere.
- Micro-consistency: border radii, shadow levels, focus-ring style,
  disabled treatment, and transition durations match established values —
  compare computed styles against a known-good existing screen.

## Polish defects

Assert per screen:

- No element misaligned 1–4px from its column or siblings (compare
  bounding rects — this is invisible in screenshots).
- Border radii consistent per component class; nested radii smaller than
  their parent's.
- Shadows from one elevation scale and one implied light source.
- No layout shift after load for the flow under review (CLS ≈ 0):
  reserved image dimensions, no font reflow, no late banners pushing
  content.
- No stacking bugs: dropdowns and tooltips never under later content;
  popovers not clipped by `overflow: hidden` ancestors; modals above
  sticky chrome.
- No horizontal page scroll at any supported viewport; no double
  scrollbars.
- Focus rings fully visible — not clipped by overflow or painted under
  neighbours.
- Buttons and labels don't wrap to an orphaned word; no collisions at
  320px or with long localized strings.
- Assets crisp at device pixel ratio 2 — no upscaled raster icons.

## Severity triage for visual findings

| Severity | Visual trigger                                                                |
| -------- | ----------------------------------------------------------------------------- |
| Blocker  | Broken layout, unusable flow, data obscured                                   |
| Major    | Wrong component used, off-system color/type, missing designed state           |
| Minor    | Spacing off the token scale, inconsistent radius/shadow, visible misalignment |
| Cosmetic | 1px optical issues, copy tweaks                                               |

Rate function separately from looks — polish does not buy leniency on
usability, and vice versa.

# Forms — labels, validation, errors, submit

## Labels

- Every input has a visible label in a predictable, conventional position
  — above or start-aligned per the host's design system —
  programmatically associated: clicking the label focuses the input (test
  it literally). **Unlabeled input rates at least 3** — a failed success
  criterion; cite each one that actually applies: 3.3.2 when no label or
  instruction is provided; 1.3.1 when a visible label's relationship
  isn't programmatically determinable; 4.1.2 when the control ends up
  with no accessible name at all (axe's `label` rule reports here — an
  `aria-label` satisfies it while still failing the visible-label rule
  above); 2.5.3 when a visible label's text is missing from the
  accessible name. The finding rates higher when frequency × impact ×
  persistence earns it, per SKILL.md's scale.
- Placeholder-as-label is a defect: placeholders vanish on entry, defeat
  review-before-submit, and screen readers handle them inconsistently.
- With the form filled, you can still tell what every field is.

## Required vs optional

- Both marked explicitly — required with `*` (explained once) or the word;
  optional with "(optional)". The mark-only-"(optional)" convention is
  acceptable if applied consistently. The defect is inconsistency or
  ambiguity: submit an empty form and check whether the fields that error
  were discoverable as required beforehand. (Baymard: ambiguous marking
  produced validation errors for 32% of test users.)

## Validation timing — reward early, punish late

- Never flag a field while the user is typing their first entry — type one
  character of an email and assert no error appears.
- Flag on blur or on submit. Erroring the field the user is currently in
  is a defect.
- Once a field is in error, clear the error the moment input becomes valid
  — don't make the user blur to be forgiven.
- A failed submit preserves every value the user entered.
  **Blocker: form clears on validation error.**

## Error messages

- Adjacent to the offending field (directly below or beside), in text —
  not color alone, not only a red border.
- Specific and actionable ("Enter an email address in the format
  name@example.com"), blame-free — no "invalid", "illegal", "forbidden".
- Multi-error submit: an error summary at the top that receives focus and
  links each entry to its field; at minimum, focus moves to the first
  errored field. Check the wiring: `role="alert"` or a live region,
  `aria-invalid`, `aria-describedby`.
- A server-side failure after submit gets a message distinguishing "your
  data is wrong" from "the service failed" — never field-validation
  styling for a problem the user cannot fix.

## Input plumbing

- `type`/`inputmode` match the data: email → `type=email`, phone →
  `type=tel`, verification codes → `inputmode=numeric`.
- `autocomplete` tokens present on identity, address, and payment fields
  (`name`, `email`, `postal-code`, `cc-number`, …) — also WCAG 1.3.5.
- `spellcheck="false"` on names, emails, reference codes.
- Nothing blocks paste — especially password and confirmation fields
  (also WCAG 3.3.8).

## Data loss

- An in-app route change silently discarding a half-filled form is a
  defect (see navigation.md, unsaved changes).
- Multi-step forms: position shown ("Step 2 of 4"), Back preserves entered
  data (test it), a review step precedes any consequential submission
  (also WCAG 3.3.4).
- Within one process, the user never re-enters information already given —
  auto-populate or offer selection (WCAG 3.3.7).

## Submit

- Prefer an enabled submit that validates over disabled-until-valid:
  disabled submits explain nothing, aren't focusable, and — being exempt
  from WCAG contrast minimums as inactive controls — are often barely
  perceivable.
  If the host's convention is a disabled submit, it must sit beside
  visible guidance on what's missing, and the disabled state must be
  perceivable.
- Whatever the pattern: clicking submit on an empty form produces a
  visible response. **Blocker: dead submit click.**
- Double-submit protection guards the submit event, not just the click —
  Enter can bypass a click-only guard. On submit the form enters a
  loading state ("Saving…") and one user action produces one logical
  mutation; a deliberate retry path is separate and idempotent.
  **Blocker: duplicate mutation requests.**

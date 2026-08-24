# Method — how experts find UX defects

Structured inspection methods, run as separate passes. Each catches what the
others miss; blending them into one walkthrough finds a fraction of what
structured passes find (the evaluator effect: evaluators using the same
method on the same UI overlap on only ~20% of problems — Hertzum &
Jacobsen 2001).

How to use this file: the mode you are in sequences the work — walkthrough
first, heuristic sweep second, findings written per the protocol at the
end. The lists below are consulted _during_ those passes; they are not a
reading order.

## Nielsen's ten heuristics, as checkable violations

**1. Visibility of system status**

- An action leaves the UI visually unchanged while work happens.
- A fetch that can exceed 1s has no indicator; an operation past 10s has no
  determinate progress.
- Save/delete/submit succeeds with no confirmation — the user must guess.
- Current location absent from nav, breadcrumb, page title, `document.title`.

**2. Match between system and the real world**

- Raw enum values (`PENDING_APPROVAL`), UUIDs, or database field names on
  screen.
- ISO timestamps, unlocalized numbers, unrounded floats (`12.300000000004`).
- Information ordered by API response shape, not the user's workflow.

**3. User control and freedom**

- A modal or multi-step flow with no working Cancel/Close/Back.
- Browser Back breaks state, re-submits, or traps.
- A destructive or bulk action with no undo and no confirmation.
- Exiting a form silently loses data.

**4. Consistency and standards**

- One operation named differently in different places ("Remove" / "Delete" /
  "Archive" for the same thing).
- Confirm buttons switching sides between dialogs; primary-button styling
  inconsistent.
- Links that don't look like links; clickable-looking chrome that isn't;
  the reverse.

**5. Error prevention**

- Illegal options selectable, then rejected on submit (past dates, invalid
  combinations).
- Free text where a mask, stepper, or picker fits.
- Rapid double-click on Submit creates two records.
- Destructive actions adjacent to and styled like safe ones.

**6. Recognition rather than recall**

- The user must remember data from a previous screen to finish this one.
- Constraints (format, limits, required-ness) revealed only by the
  rejection message.
- A failed submit wipes the form.

**7. Flexibility and efficiency of use**

- No sensible defaults on frequent-path fields.
- Search/filter state lost on navigation.
- Enter doesn't submit; keyboard-only operation broken.
- Repeated multi-item operations forced one at a time.

**8. Aesthetic and minimalist design**

- Multiple competing primary buttons on one screen.
- Debug output, redundant IDs, decorative noise obscuring content.
- Layout collapses at realistic data volumes.

**9. Help users recognize, diagnose, and recover from errors**

- Raw status codes, stack traces, `[object Object]`, or "Something went
  wrong" with no recovery path.
- Field errors not adjacent to their field; no scroll/focus to the first
  error.
- No Retry after a network failure; "your input is bad" indistinguishable
  from "the server failed".

**10. Help and documentation**

- Non-obvious fields with no inline hint at the point of need.
- Blank empty states where an instructive one belongs.

## Cognitive walkthrough

Task-centred, first-time-user learnability. Script the task; at every
discrete step answer four questions. Any "no" is a finding, written as the
story of why a new user fails:

1. Will the user try to achieve the right result — do they know this step
   is needed?
2. Will they notice the correct action is available (not hidden behind
   hover, overflow menus, scroll)?
3. Will they associate the action with their goal — does the label plainly
   mean what it does?
4. After acting, will they see progress was made?

## Beyond Nielsen — the additions worth checking

- **Closure** (Shneiderman): flows end with an explicit completion signal
  and a "what next", not a silent redirect.
- **Suitability for the task** (ISO 9241-110): no step exists only for the
  system's benefit; the user never re-enters data the system already has.
- **Error tolerance** (ISO 9241-110): evident input errors are corrected
  with minimal user action — pasted whitespace accepted, obvious formats
  normalized.
- **Fitts's law** (Tognazzini): frequent targets large and close; dangerous
  ones distant from safe ones.
- **Anticipation** (Tognazzini): the information needed for a decision is
  brought to the decision point (the balance next to the amount field).
- **Protect users' work** (Tognazzini): no crash, timeout, or navigation
  slip may lose work. Treat as a hard assertion.

## Evaluator biases and their countermeasures

- **Evaluator effect** → run multiple structured lenses as separate passes;
  don't merge them into one walkthrough.
- **Confirmation bias** → the goal of a pass is to make the task fail. A
  pass that follows the happy path confirms; it does not test.
- **Curse of knowledge** → the walkthrough explicitly role-plays a
  first-time user who has not read the spec.
- **Aesthetic–usability effect** → polished UIs get lenient judgments; rate
  function separately from looks.
- **Anchoring on the spec** → "matches the ticket" is not "usable". Review
  against user goals, not acceptance criteria alone.

## Write-up protocol

One problem per finding — never bundle. Each cites location, description,
the principle violated, evidence, and severity. Severity is rated after the
pass completes, against the full finding list, not on first impression.
Findings you suspect but cannot reproduce are logged as questions.

The audience is the engineer who will fix it. A finding is a few terse
lines: concrete nouns, reproduction, consequence — no essays, no restating
the criteria, no reviewer jargon. If a finding needs a paragraph, that
paragraph is the evidence, not prose around it.

# Mode: spec-review — catch UX gaps before code exists

Read the references as **requirements**: every assertion the assess mode
would test is a question the spec should already answer. A gap found here
costs a sentence; found at assess time it costs a rework.

## Input

Review what the argument points at — a spec directory, an RFC, a PRD, an
issue, a plan, a task list. Read all sibling artifacts (plan, tasks) when
they exist; gaps often hide between them (spec names a state, no task
builds it).

If the code already exists, review the artifacts as written first, then
note per gap whether it materialised as an implementer-invented decision —
the implementation's answer never closes a spec gap.

Findings follow the write-up protocol in `references/method.md`: one gap
per finding, atomic, with its evidence.

## What a UI-bearing spec must answer

Work through these against the artifact. Each unanswered question is a
gap finding; each contradiction between artifacts is too.

**States** (`references/states.md`)

- What does every screen show when empty, loading, partial, error —
  first-run empty as well as empty-search-results?
- What happens on network failure mid-action? Is there a retry story?
- What are the realistic data extremes (longest name, largest count) and
  what does the layout do with them?

**Flows and navigation** (`references/navigation.md`, `references/method.md`)

- Is the task flow specified from a first-time user's view — entry point,
  each step's feedback, explicit completion and "what next"? Walk it with
  the cognitive-walkthrough questions from `references/method.md`; they
  find the flow gaps a checklist read misses.
- What state lives in the URL? What must survive refresh, Back, and a
  shared link?
- What happens to unsaved work on navigation, session expiry, refresh?

**Forms** (`references/forms.md`)

- Is every field's label, required-ness, format, and validation message
  specified? Who writes the error copy, and does it follow
  specific/actionable/blame-free?
- When does validation fire? What does a failed submit preserve?

**Feedback** (`references/feedback.md`)

- How does each mutation acknowledge within a second — update in place,
  inline confirmation, or status message?
- Which updates are optimistic, and what does the user see when one
  fails and rolls back?
- Which status messages must be announced to assistive tech (live
  regions), and does the spec name them?

**Destructive and consequential actions** (`references/feedback.md`)

- Undo or confirm — which, and why? What exactly does the confirmation
  say? For legal, financial, or user-data submissions specifically: which
  of reversible / checked / confirmable applies (WCAG 3.3.4)?

**Accessibility** (`references/accessibility.md`)

- Does the spec commit to WCAG 2.2 AA as acceptance criteria, or is it
  silent? Silence is a gap.
- For custom widgets: which APG pattern, what keyboard contract?
- Focus behavior on route change, on modal open/close, on element
  removal.

**Consistency** (`references/visual.md`)

- Does the spec reuse the host's existing components and patterns, or
  quietly introduce new ones? A new pattern needs a stated reason.
- Does the spec contradict the host design doc's _rules_ (layout counts,
  page anatomy, copy voice), not just its component list? Diff against
  the rules, not only the inventory.
- Any new copy: does terminology match the rest of the product?

**Tasks coverage** (when a task list exists)

- Is there a task for each non-ideal state the spec names?
- Is accessibility work in the tasks, or assumed to happen for free?
- Is anything in the spec unbuildable as written (undefined empty state,
  unspecified error copy) that will force an implementer to invent?

## Report

0. **Discovery note** — what was found and used (design system, spec
   artifacts), per SKILL.md's discovery contract.
1. **Gaps**, ordered by cost-if-missed: **blocking** (would force rework
   or an invented decision at implementation time), **should-specify**
   (implementer could guess, guesses will diverge), **note** (minor).
   Gaps are deliberately not rated on the 0–4 defect scale — nothing is
   broken yet — but they anchor to it: a blocking gap is one whose miss
   would land as severity 3–4 at assess time, should-specify as 2, note
   as 1.
2. For each gap: the question the spec doesn't answer, where it belongs
   (spec/plan/tasks — or the host's design doc, when the gap is a missing
   product-wide pattern no single spec can own), and a **proposed
   addition** — concrete wording the author can accept or edit, not just
   "underspecified".
3. Contradictions between artifacts, cited by location.
4. What the spec already covers well — one line, so the author knows
   what not to touch.

Where the host's flow supports it (a tasks file, an issue tracker), offer
to append the accepted gaps as tasks rather than leaving them in prose.

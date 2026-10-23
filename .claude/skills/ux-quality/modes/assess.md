# Mode: assess — adversarial UX quality assessment

Review built functionality by trying to break it. The output is a
severity-gated verdict with evidenced findings — not a tour of what works.

## 0. Intake

Establish before driving anything:

- **Scope.** Which feature, routes, and flows are under review. Unscoped
  "review the app" → agree the top user tasks first.
- **Scope tier.** Full five-pass coverage of even a small feature is
  multi-hour work. Agree the tier up front: **sample** (representative
  surfaces per pass → the verdict is at best partial) or **exhaustive**
  (every surface and state → eligible for pass).
- **Discovery** (per SKILL.md): design system, app URL, browser tooling,
  driver agent. State what you found.
- **Data control.** How to force states: can you intercept or block API
  routes, point at a seeded environment, or create/delete records through
  the UI? The stress pass depends on this — plan it now.
- **Screenshot home.** Pick one directory for the run's evidence; the
  host may have a convention for this.

## 1. The passes

Run as **separate passes in this order**, each producing its own findings
before the next begins (the evaluator effect is the reason: merged passes
find less). Log findings per the write-up protocol in
`references/method.md`; severity per SKILL.md.

### Pass 1 — First-time-user walkthrough

This pass fits scopes with a task flow. When the scope is not a flow —
a single component, a panel, a static page — walk its primary operations
instead, or skip the pass with a stated reason; the scope intake decides
which.

Load `references/method.md`. Script the primary task(s); execute each
step in the browser as a user who has not read the spec. At every step,
answer the four cognitive-walkthrough questions. Also judge closure: does
the flow end with explicit completion and a "what next"?

### Pass 2 — Heuristic and interaction sweep

Load `references/method.md`, `references/forms.md`,
`references/feedback.md`, `references/navigation.md`. Screen by screen,
element by element: the ten heuristics' checkable violations, form
criteria, feedback criteria, navigation criteria. Run copy as its own
lens within this pass — every label, error and empty state against the
microcopy criteria, plus the host's voice guide and customer vocabulary
where discovery found each; with neither, judge internal consistency
only. Drive
interactions — hover, focus, submit, cancel — don't just look.

### Pass 3 — Accessibility

Load `references/accessibility.md` and `references/tooling.md`.

1. Inject axe with the WCAG 2.2 AA tag set; run **per state** (each
   route, modal open, error state, dark mode if the host has one).
   Triage `violations` and work the `incomplete` queue.
2. Run the keyboard procedure end to end on the flows under review.
3. Emulation checks: 320px reflow, 200% zoom, text-spacing injection,
   reduced-motion, forced-colors, grayscale (color-only cues).
4. SPA checks: route-change title and focus, live regions pre-existing,
   modal focus cycle, focus after element removal.

### Pass 4 — State and data stress

Load `references/states.md`. Force all five states per screen (block
routes, return empty/one/500, throttle). Inject adversarial data. Run the
interruption and concurrency sweep. Watch console and network the whole
time — errors the UI never surfaces are findings.

### Pass 5 — Visual craft

Load `references/visual.md`. Run the host's conformance checks over the
scope's source first: each new offence is a finding (Minor unless it
meets a higher trigger), cited by the check's name. Screenshot the
viewport matrix (320 / 375 / 768 / desktop) per key state, in each theme
and scheme of the host's matrix. Judge overall composition from
screenshots; verify anything numeric (alignment, token conformance,
target sizes) with measurements. Compare component usage against the
host's design system.

## 2. Driving discipline

- Delegate driving to the discovered driver agent where one exists; keep
  every judgment in this context. Read the screenshots yourself.
- One driver at a time if the browser is shared.
- Time-box every driver dispatch and say so in its prompt; cap
  per-element retries and forbid unbounded waits — one wedged browser
  call must cost minutes, not hours. A dispatch that misses its box
  returns what it has plus what's missing.
- Passes mutate the app — created records, storage, dirty forms. Each
  pass ends by recording the state it leaves behind; each later pass
  restates the baseline it needs and re-establishes it rather than
  assuming a clean slate (yesterday's adversarial record is today's
  "default" first row).
- Never assert what you didn't verify. If a state could not be forced or
  a check could not run, it goes in the report as **not verified**, not
  as a pass.

## 3. Report

Structure:

1. **Verdict** — pass / partial / fail. Any severity-4 finding fails the
   assessment, regardless of what else ran. **Pass** requires every
   applicable pass to have run and every in-scope state forced. A pass
   skipped as not applicable to the scope, with the reason stated, does
   not block a pass verdict; a pass skipped for any other reason caps
   the verdict at **partial** — as does blocker-free-but-incomplete
   coverage, naming what wasn't verified. List blockers first.
2. **Findings**, most severe first, each standing alone: severity ·
   location · what happens (reproduction) · task consequence · evidence
   (screenshot path, measurement, trace) · principle violated.
   Low-confidence ratings marked; unreproducible suspicions listed as
   questions.
3. **Not verified** — what the run couldn't check and why.
4. **What was attacked** — the passes run, states forced, data injected,
   viewports covered. This is what makes a "no findings" pass credible.

Severity-3 findings don't fail the verdict but are enumerated for triage;
deliberate deviations get a UX-debt label with a pointer to whoever owns
the decision. Findings rated 0 stay in the report with the reasoning.

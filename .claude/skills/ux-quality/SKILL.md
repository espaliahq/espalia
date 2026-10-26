---
name: ux-quality
description: UX/UI quality expertise for the whole development lifecycle. Three modes — build (apply UX/accessibility best practice while designing or implementing UI), spec-review (review a spec, plan, PRD or task list for UX gaps before code exists), assess (adversarial UX and WCAG 2.2 AA quality assessment of implemented functionality in a real browser). Use when building or changing UI, when reviewing a feature spec or plan for UX completeness, or when asked to QA, review or assess the usability, UX or accessibility of a feature.
---

# ux-quality

One body of UX/UI knowledge applied at three points in the lifecycle. The
criteria live once, in `references/`, phrased as checkable assertions; each
mode reads them at a different grain — as requirements (spec-review), as
defaults (build), or as tests to execute (assess).

## Modes

| Invocation                                 | Mode file              | When                                      |
| ------------------------------------------ | ---------------------- | ----------------------------------------- |
| `/ux-quality assess [scope]`               | `modes/assess.md`      | Adversarial review of built functionality |
| `/ux-quality spec-review <path or target>` | `modes/spec-review.md` | Spec/plan/tasks exist, code doesn't       |
| `/ux-quality build`                        | `modes/build.md`       | About to design or implement UI           |

No mode named: infer from what exists (running code → assess; artifacts only
→ spec-review; about to write UI → build) and say which you chose.

Read the mode file, the discovery section below, and only the references the
mode calls for. Do not load every reference up front.

## Discovery — resolve the host repo before any mode runs

This skill carries no facts about any particular repository. Resolve each of
these from the host, in order, and note what you found in your output:

1. **Design system.** Look for a design doc (`DESIGN.md` or similar), a
   tokens/theme file, a design-system package in `package.json`, component
   conventions in `CLAUDE.md`/`AGENTS.md`. Note any named spacing
   semantics (which gap goes within a group vs between groups), any
   voice or copy guide, and the customer vocabulary — the product's
   names for its users and domain objects. The proximity and microcopy
   criteria consume all three.
   Found → consistency criteria in `references/visual.md` run against it.
   Not found → fall back to the generic craft rules; do not invent a
   system. With a design system, also resolve:
   - **Component catalogue:** where a job maps to a component (a docs
     table, Storybook, Lookbook), so build mode picks before it writes.
   - **Conformance checks:** the lint rules and guard tests that enforce
     the system, and how the host marks existing violations (a lint
     todo or baseline). Marked code is debt, never a model to copy.
   - **Theme matrix:** every theme, colour scheme and seeded stress
     fixture the UI must hold up in. Default-only evidence hides the
     bugs the other themes carry.
   - **House rules stricter than AA,** such as a larger touch target
     for key actions. Build to them; report a miss as a house-rule
     finding, never as a WCAG failure.
2. **App URL and how to run it.** Host docs first; a project `run`-style
   skill second; probing last. Never start servers the host docs say the
   user owns.
3. **Browser tooling.** Whatever automation the host exposes — a
   chrome-devtools MCP, a Playwright MCP, a CLI skill. Modes are written
   against capabilities (navigate, screenshot, evaluate JS, emulate
   viewport/media, read console/network), not one tool's function names.
4. **Driving delegation.** If the host defines a browser-driver agent, use
   it and keep judgment in the caller. Otherwise use the bundled
   `agents/ux-driver.md` if it is registered, else drive inline.
5. **Spec artifacts** (spec-review only). Review what the argument points
   at — a spec directory, an RFC, a PRD, an issue. Never assume one format.

Missing pieces degrade the mode, they don't abort it: without browser
tooling, assess runs its static passes and reports what it could not
verify. An honest partial verdict beats a hard dependency.

## Severity — one scale for every mode

| Rating | Label     | Trigger                                                                                                  |
| ------ | --------- | -------------------------------------------------------------------------------------------------------- |
| 4      | Blocker   | Task cannot be completed; data lost or corrupted; user misled into a costly outcome; no workaround       |
| 3      | Major     | Completion severely impaired; workaround exists but hard to find; a failed WCAG 2.2 AA success criterion |
| 2      | Minor     | Users slowed or irritated but recover; learnable                                                         |
| 1      | Cosmetic  | Polish only; no task impact                                                                              |
| 0      | Not a bug | Recorded with reasoning, never silently dropped                                                          |

Rate against **frequency × impact × persistence**. Every 3–4 must name the
task consequence ("user cannot recover their draft"), not just the principle
violated. Mark low-confidence ratings as such — a single evaluator's
severity is known to be unreliable. Suspected-but-unreproducible findings
are logged as questions, not dropped. Intentional, deferred deviations are
labeled UX debt, never silently shipped.

## Evidence rules

- Screenshots for overall composition; measurements for anything numeric. Never assert
  a pixel value, color, or spacing from a screenshot — read computed styles,
  bounding rects, the accessibility tree.
- Every finding stands alone: location, reproduction steps, evidence
  (screenshot path, measurement, console/network trace), the principle
  violated, severity with rationale.
- A pass that finds nothing is a weak pass, not a clean bill. Say what you
  tried to break and how.
- Write for the engineer who will fix it: a few terse lines per finding,
  concrete nouns, no essays.

## Scope guard — AA, not AAA

Accessibility criteria are WCAG 2.2 Level A + AA only. Do not demand AAA:
no 44×44 minimum target size (AA is 24×24 — 44pt/48dp are platform
_recommendations_, cite them as such), no 7:1 contrast, no Focus Appearance
metrics. Over-reach discredits the review.

## References

| File                          | Holds                                                                                               |
| ----------------------------- | --------------------------------------------------------------------------------------------------- |
| `references/method.md`        | Heuristics with checkable violations, cognitive walkthrough, evaluator biases, review protocol      |
| `references/states.md`        | The five UI states, loading thresholds, error-handling UX, adversarial data and interruption sweeps |
| `references/forms.md`         | Labels, validation timing, error messages, submit behavior                                          |
| `references/feedback.md`      | Button states, acknowledgment, optimistic UI, toasts, destructive actions, microcopy                |
| `references/navigation.md`    | Wayfinding, Back, deep links, unsaved changes                                                       |
| `references/accessibility.md` | WCAG 2.2 AA criteria and numbers, keyboard procedure, SPA pitfalls, automated-coverage limits       |
| `references/visual.md`        | Typography, spacing, color, design-system consistency, polish defects                               |
| `references/tooling.md`       | axe injection, emulation, measurement recipes, console/network signals                              |

## Portability rule

Nothing in this directory may name a host repo's design system, URLs,
agents, or spec tooling. Host specifics belong in the host's own docs,
found via discovery. If you are tempted to write a host fact into this
skill, that is a bug — put it in the host's docs instead.

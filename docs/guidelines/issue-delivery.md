# Delivering One Issue, End to End

> Read this when: handing a single GitHub issue to an agent (or picking one up
> yourself) to be taken from "open" to "PR green and reviewed" without
> supervision. It is the delivery contract — the process rules that sit around
> whatever the issue actually asks for.

The rules below are the ones that, when skipped, produce work that has to be
redone: an issue nobody knew was being worked, a branch off the wrong base, a
PR that looks reviewed and isn't. Everything else — how to write a controller,
a view, a test — lives in the layer guidelines that
[AGENTS.md](../../AGENTS.md) points at. Read those for every layer the issue
touches **before** writing code; do not rely on defaults.

## Ground rules

1. **Claim the issue before touching anything.** `gh issue edit <n> --add-label
   in-progress` and a comment saying which branch you're on. Nothing in this
   repo manages labels declaratively, so `in-progress` may have been deleted
   since you last used it — if the edit fails with "not found", recreate it
   (`gh label create in-progress --color FBCA04 --description "Being actively
   worked on (agent or human)"`) and retry. Comment the PR link on the issue
   once the PR exists, so the issue is a complete record on its own.
2. **Branch from the stated base, not habitually from `main`.** If the work
   stacks on an unmerged branch, branch from that and open the PR with
   `--base <that branch>`; say in the PR body which PRs it stacks on. As each
   lands, retarget with `gh pr edit <n> --base <next>`. Before opening the PR,
   check `git log <base>..HEAD` shows only your commits — a stack that has
   absorbed someone else's work is very hard to unpick later.
3. **Don't make the routine calls into questions.** The delegator is not
   watching. Decide, do it, and state the assumption in the PR body.
4. **Stay inside the issue's scope.** Neighbouring problems usually have their
   own issues. If you must touch shared code, keep the change minimal and say
   so in the PR. Drift you find but don't fix belongs in a comment on the
   relevant issue, not in your diff.
5. **Commit each discrete change the moment it is complete and verified** —
   stacked commits, one PR, conventional messages that say what value was
   created. This is the repo-wide rule in
   [AGENTS.md](../../AGENTS.md#behaviours-and-practices); it matters more when
   nobody is reviewing the working tree as you go.
6. **Every behaviour change gets a test.** A system test (both viewports for
   anything responsive), and for a new controller action a controller test
   including the denied-access path. Follow
   [testing.md](testing.md) — especially the JS-dispatch helpers; the
   `SystemTests/FlakeProneClick` cop fails CI on the worst patterns.
7. **A front-end change needs the Chrome MCP visual pass too**, and it is not
   discharged by the test suite. Delegate the driving to the `chrome-driver`
   agent, then read the screenshots and judge them yourself — see
   [chrome-mcp.md](chrome-mcp.md) for the URL, credentials, viewports and
   gotchas. One browser driver at a time.
8. **`bin/rails development:precommit` must be fully green before the PR.** Run
   it directly, never piped, as a foreground call with a long timeout. Fix
   everything it reports, including what looks unrelated.
9. **Run `/code-review` on the branch diff before opening the PR.** Verify each
   finding against the code, land the real ones as their own stacked commits,
   and say in your final report which you skipped and why.
10. **Update the guidelines your change falsifies** — in the same PR, not as a
    follow-up. If the change adds or changes a user-facing read/write surface,
    either route it through `Operations::*` or state in the PR why MCP exposure
    doesn't apply ([mcp-server.md](mcp-server.md)).
11. **Open the PR with the full body**: Why / What / Measured (real numbers
    where the issue asked for them) / MCP note / Tests / Docs / Screenshots,
    `Closes #<n>`, and the Claude Code footer. Screenshots need the PR's
    number, so open the PR first, then run `bin/pr-screenshots <n> <files…>`
    and edit the printed links into the Screenshots section. Seeded dev data
    only.
12. **Track CI, then track the review.** `gh pr checks <n> --watch` in the
    foreground. Then read CodeRabbit's *unresolved review threads* over
    GraphQL — `gh pr checks` does not reveal findings, and on a **stacked** PR
    CodeRabbit skips auto-review entirely (see AGENTS.md → Learnings). Fix each
    real finding as its own commit, push, re-watch, and repeat until CI is
    green and nothing unresolved is left unanswered.
13. **Never merge, force-push, rewrite pushed history, delete branches, or
    touch production.** Writes to the dev tenant during verification are fine;
    keep them recognisable.

## Long-running work: block, don't poll

Precommit, the test suite and `gh pr checks --watch` run as **foreground**
calls with a long timeout so the call blocks. Anything genuinely backgrounded
(a subagent, a `/code-review` angle) reports back by notification — do other
work or end your turn and wait. Never `sleep`, tail a file in a loop, or
re-check for a result that will arrive on its own.

## Working alongside other agents

Subagents share your checkout, your dev database and your dev server on
port 6600 (AGENTS.md → Learnings). While one is working, don't switch branches
or reset seed data underneath it, and don't start a second browser driver.

## What the delegator owes you

An issue body carrying the problem, the measurements or reproduction, the files
in play, the acceptance criteria, and the intended approach; plus the base
branch if it isn't `main`. If any of that is missing, the first action is
usually a comment on the issue pinning down what you assumed.

## The final report

Whoever delegated the issue sees only your closing message. Include: the PR
link, the commits, before/after numbers, what the visual pass showed, findings
you skipped and why, anything deliberately left out of scope, and the branch
name.

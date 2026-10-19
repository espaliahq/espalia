# Delivering One Issue, End to End

> Read this when: opening or updating any PR, and before handing a single
> GitHub issue to an agent (or picking one up yourself) to be taken from "open"
> to "PR green and reviewed" without supervision. It is the delivery contract —
> the process rules that sit around whatever the issue actually asks for.

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
    only — see [Screenshots in the PR body](#screenshots-in-the-pr-body).
12. **Track CI, then track the review.** `gh pr checks <n> --watch` in the
    foreground. Then read CodeRabbit's *unresolved review threads* over
    GraphQL — `gh pr checks` does not reveal findings, and on a **stacked** PR
    CodeRabbit skips auto-review entirely (see
    [Reading a PR's review](#reading-a-prs-review-what-coderabbit-can-hide)). Fix each
    real finding as its own commit, push, re-watch, and repeat until CI is
    green and nothing unresolved is left unanswered.
13. **Never merge, force-push, rewrite pushed history, delete branches, or
    touch production.** Writes to the dev tenant during verification are fine;
    keep them recognisable.

## Reading a PR's review: what CodeRabbit can hide

**`gh pr checks` does NOT reveal CodeRabbit findings.** Its CodeRabbit row reports the *check* status (e.g. "Review skipped" / "pass") which is independent of the review CodeRabbit posts as PR *review comments*. A green/"skipped" row can still hide actionable findings. Never conclude "no findings" from `gh pr checks` alone. Extraction rules (each learned the hard way):

- **Read every CodeRabbit review *body*, not just the threads.** Findings on lines outside the PR's diff cannot be posted inline; CodeRabbit puts them in the review body under "Outside diff range comments" (`gh pr view <n> --json reviews --jq '.reviews[] | select(.author.login=="coderabbitai") | .body'`). They are real findings with no thread to resolve — address them and say so in a PR comment. One was missed on [PR #410](https://github.com/mr-yum/growth-os/pull/410) by reading threads alone.
- **The source of truth for OPEN findings is GraphQL review threads, not the REST comment list.** `isResolved` only exists there: `gh api graphql -f query='query { repository(owner:"OWNER", name:"REPO") { pullRequest(number: N) { reviewThreads(first: 100) { nodes { isResolved isOutdated path line comments(first: 10) { nodes { author { login } body databaseId } } } } } } }'` and filter `isResolved == false`. CodeRabbit auto-resolves threads it verifies as fixed, so unresolved == still owed a fix or a reply.
- **Never time-window filter (`created_at > <timestamp>`) to find "new" comments** — a review that lands seconds before your guessed cutoff vanishes silently (this exact miss happened on [PR #301](https://github.com/mr-yum/growth-os/pull/301)). Ask for unresolved threads instead.
- **Always `--paginate`** on `gh api repos/{owner}/{repo}/pulls/<n>/comments` — the default page is 30 and a multi-round PR exceeds it quietly.
- `gh pr view <n> --json reviews --jq '…coderabbitai…'` still covers review-level bodies (walkthrough, "actionable comments posted: N").
- Replying does NOT resolve a thread; a fix push usually gets auto-resolved by CodeRabbit once verified. Check the unresolved count again after replies/pushes rather than assuming.

CodeRabbit can also post no review at all and still show a green row. Check for each skip before reading silence as clean:

- **CodeRabbit's rate limit also refuses the manual `@coderabbitai review` trigger, and its "wait N minutes" is not reliable.** A limited PR shows a "Review limit reached" comment and `gh pr checks` reports the CodeRabbit row as `pass` with "Review rate limited" — a green row, no review. Posting `@coderabbitai review` inside the limit answers "Action not completed — Review rate limited" ([PR #404](https://github.com/mr-yum/growth-os/pull/404) was refused 22 minutes after a "wait 7 minutes" notice; a later retry got "Review triggered"). So: never read a rate-limited PR as clean, retry the trigger until the reply says "Review triggered", then poll for the summary comment ("No actionable comments…" / "Actionable comments posted: N") plus the GraphQL unresolved-thread count. The "Run on-demand review" checkbox draws on paid capacity after the free window; leave that to a human.
- **CodeRabbit does not auto-review a PR whose base is not the default branch.** It posts "Review skipped — Auto reviews are disabled on base/target branches other than the default branch" and nothing else, which reads exactly like a clean review. This bites every stacked PR (base = the branch below it), which is the shape this repo asks for when work is split across issues. Two remedies: comment `@coderabbitai review` to trigger a single review while the PR is still stacked, and re-check after `gh pr edit <n> --base <next>` retargets it as the stack lands. Never treat the absence of CodeRabbit comments on a stacked PR as "no findings" — check for the skip notice first (`gh pr view <n> --json comments -q '.comments[]|select(.author.login=="coderabbitai")|.body'`). Repo-wide auto-review on other bases would need `reviews.auto_review.base_branches` in `.coderabbit.yaml`; it is deliberately not set today.
- **A PR opened by a bot gets no review.** Every Dependabot PR is unreviewed; see [dependencies.md](dependencies.md).

## Screenshots in the PR body

**Include screenshots in PR descriptions to demonstrate new or changed user-facing functionality, when appropriate.** Any PR that adds or changes a front-end surface should show the result in its description — a `## Screenshots` section with the new/changed UI (both viewports when the change is responsive; before/after when it changes existing UI). The mandatory Chrome MCP visual pass already captures these under `tmp/visual/<task>/` (see [chrome-mcp.md](chrome-mcp.md)). GitHub has no image-upload API, so publish them to this repo's orphan **`screenshots` branch** with `bin/pr-screenshots <pr-number> tmp/visual/<task>/<file>.png …` and paste the markdown it prints into the PR body. It needs the PR's number, so open the PR first, then publish and edit the links in. Each image lands under `pr-<n>/` on that branch, which shares no history with `main`. The commit is built with git plumbing and a throwaway index, so the working tree and the current branch are never touched. The links are pinned to the upload's commit, so a later upload can't change an old PR. Because the repo is private, the images render only for people signed in to GitHub with read access. Never commit screenshots to `main` or a feature branch; `tmp/visual/` stays gitignored. **`bin/pr-screenshots` is pre-authorized** via `.claude/settings.json`, so use it by default without asking. The branch is visible to everyone with repo access and is never cleaned up, so publish seeded or demo data only; dev names are whimsified pseudonyms, so dev-tenant screenshots qualify. Never upload a screenshot showing real customer data, credentials or tokens, by this script or by dragging it into the PR editor, which uploads it to GitHub just the same. Redact it or recapture it on seeded data, and leave it out if you can't. Name files for what they show (`desktop-1400-feed-end.png`, not `05b.png`), since the file name, without its extension, becomes the alt text. Skip screenshots entirely for purely backend/internal changes with no visible surface.

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

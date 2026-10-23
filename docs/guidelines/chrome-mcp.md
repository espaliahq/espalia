# Chrome MCP — Visual Validation

> Read this when: driving the running app in a real browser via the
> `chrome-devtools` MCP — the **mandatory visual-verification pass** for any
> front-end change, exploring a new flow, or reproducing a user-reported UI bug.
>
> **This is an *additional* gate, not a replacement for system tests.** System
> tests remain the source of truth and MUST represent every piece of
> functionality (see [testing.md](testing.md)). The system test proves the
> behaviour *keeps* working under CI; the Chrome MCP pass proves it *actually
> looks and behaves right* right now. A front-end change is done only when
> **both** are true — a system test covers it AND you've laid eyes on it here.
> CI runs the system tests; it does not run the MCP, so the MCP pass never
> substitutes for writing one.

## Delegate the driving to the `chrome-driver` subagent (default)

Driving the browser in the main context is expensive: each `take_snapshot` is a
5–30k-token element tree and a typical pass burns 10–15 tool calls. **Default to
dispatching the [`chrome-driver`](../../.claude/agents/chrome-driver.md) agent**
(Agent tool, `subagent_type: "chrome-driver"`) with the flow to drive and a
short task name; all the snapshot/interaction noise stays in its context. It
signs in, drives the flow at both viewports, saves screenshots under
`tmp/visual/<task>/`, collects console errors, and returns a compact report
(steps, errors verbatim, screenshot paths, anomalies).

**The delegation covers driving only — never the visual judgment
(NON-NEGOTIABLE).** After the agent returns, `Read` the saved screenshots and
judge them yourself: layout, contrast, responsive behaviour, whether the change
actually looks right. "The subagent said it looked fine" does not discharge the
visual pass — the whole point of this gate is that *you* lay eyes on the change.
Treat the agent's "anomalies" section as leads, not verdicts.

Practical notes:

- **Model:** the agent defaults to Haiku — right for scripted capture ("log in,
  go to X, click Y, screenshot both viewports"). For exploratory bug repro,
  where the driver must notice something unexpected and adapt, pass
  `model: "sonnet"` on the Agent call.
- **The edit-mode explorer overflows the driver's context — on ANY model,
  through `take_snapshot` AND `wait_for`.** One snapshot of `/frameworks/:id/edit`
  on the seeded framework is a ~190 K-character accessibility tree; the Haiku
  driver died on its second one ("Prompt is too long") before taking a single
  screenshot, and `wait_for` returns the same tree in its own result, so a
  "safe" text sync blows the budget just as surely. For that page, tell the
  driver up front: never `take_snapshot` or `wait_for` there; find, inspect and
  click with `evaluate_script` returning small strings/JSON (`el.click()` for
  hover-revealed controls, since headless reports `hover: none`), poll for
  state with `evaluate_script`, and use `take_screenshot` for evidence. Pass
  `model: "sonnet"` for headroom. The sign-in page and the frameworks index are
  small enough to snapshot.
- **One driver at a time.** `chrome-debug` is a single shared browser — never
  run two driving agents concurrently.
- **Inline driving is still fine for trivial checks** — a single
  `evaluate_script` or one screenshot doesn't warrant a dispatch. The moment a
  flow needs snapshots or multiple interactions, delegate.
- If the flow is already pinned by a system test, `SCREENSHOTS=1` +
  `/screenshot-test` is cheaper still — deterministic artifacts, no browser
  driving at all.

The rest of this document is the recipe the subagent's definition bakes in —
you still need it when driving inline, debugging the agent, or updating its
definition (keep the two in sync when gotchas change).

## How it's wired (devcontainer)

- Claude Code runs in the **`rails-app`** container. The browser is a **separate
  `chrome-debug`** service (`chromedp/headless-shell`) exposing CDP — see
  [.devcontainer/compose.yaml](../../.devcontainer/compose.yaml).
- [`.mcp.json`](../../.mcp.json) points `chrome-devtools-mcp` at
  **`http://localhost:9222`**.
- [`.devcontainer/start-chrome-cdp-proxy.sh`](../../.devcontainer/start-chrome-cdp-proxy.sh)
  (run by `postStartCommand` on every container start) launches a **socat
  forwarder** `127.0.0.1:9222 → chrome-debug:9222`. `socat` is installed via
  [.devcontainer/Dockerfile](../../.devcontainer/Dockerfile). It runs under
  `setsid` (its own session/process group) so it survives the `postStartCommand`
  process-group teardown — otherwise the boot-time forwarder is reaped seconds
  after starting and `localhost:9222` is dead despite the hook having "run".

**Why the forwarder is required (not optional):** Chrome 111+'s DNS-rebinding
guard rejects any CDP request whose `Host` header isn't `localhost`/an IP.
Pointing the MCP straight at `chrome-debug:9222` sends `Host: chrome-debug:9222`
and is refused; `localhost:9222` alone has nothing listening. The forwarder
bridges both: the MCP connects to `localhost:9222` (Host stays `localhost`,
which Chrome accepts) and raw bytes are piped to `chrome-debug`.

## If the MCP can't connect

Symptom: `navigate_page` fails with *"Could not connect to Chrome … Failed to
fetch browser webSocket URL from http://localhost:9222/json/version: fetch
failed"*. The forwarder isn't running. Diagnose:

```bash
pgrep -af 'socat.*9222'                 # is the forwarder up?
curl -s localhost:9222/json/version     # should return Chrome JSON
which socat                             # is socat even installed?
```

- **Forwarder down but socat present** → start it:
  `.devcontainer/start-chrome-cdp-proxy.sh`
- **`socat` missing** → your running container predates the socat addition.
  **Rebuild the devcontainer** (VS Code: *Dev Containers: Rebuild Container*) so
  the Dockerfile installs it and `postStartCommand` runs the forwarder.
  One-off stopgap without a rebuild: run any raw TCP forwarder listening on
  `127.0.0.1:9222` → `chrome-debug:9222` (a few lines of Ruby `TCPServer`/
  `TCPSocket`, or `python3 -m`… etc).
- **Verify the browser itself is alive** (bypassing the forwarder):
  `curl -s chrome-debug:9222/json/version -H 'Host: localhost'` → Chrome JSON.

## Reaching the app — use `rails-app:6600`, not `localhost`

The browser runs in the `chrome-debug` container, so **`localhost` there is
chrome-debug, not the app.** Navigate to **`http://rails-app:6600/`** (`rails-app`
is the compose service name; the dev server binds `0.0.0.0`). Start the server
with `bin/dev` if nothing answers on `:6600`.

**In a Claude Code cloud session the browser and the app share one container**, so
there it is `http://localhost:6600/`. `bin/cloud-setup` starts the browser; start the
app with `bin/rails server -p 6600`. What `bin/cloud-setup` installs, and why, is in
[dev-environment.md](dev-environment.md#cloud-sessions-bincloud-setup-not-the-devcontainer).

## Signing in

Credentials live in Rails credentials — never hardcode them. Fetch the seeded
global admin:

```bash
bin/rails runner 'a = Rails.application.credentials.dig(:admin, :user_1); puts a.email; puts a.password'
```

Then fill the Devise form (`Email`, `Password`) and submit. The seeded admin is a
global admin in the `me&u` tenant, so it can reach every surface.

## Standard viewports

GrowthOS is a responsive **desktop-first** app — most surfaces (the matrix, the
explorer three-pane, the assessment cards) are designed for the wide layout and
collapse to overlays/stacks on narrow. Verify the desktop layout first, then do a
mobile pass for anything with responsive behaviour. These mirror the
`DESKTOP_SIZE` / `MOBILE_SIZE` constants the system tests use (see
[testing.md → Responsive Behaviour Testing](testing.md)):

```text
Desktop (primary):   resize_page  width=1400  height=1400
Mobile  (iPhone):    resize_page  width=375   height=812
```

Any change that behaves differently across breakpoints (hidden/shown, sidebar vs
overlay, collapsed vs expanded) must be eyeballed at **both** sizes here — and
also pinned with a system test at both viewports per testing.md.

## Screenshot paths

When you capture visual evidence, save it under `./tmp/visual/<short-task-name>/`
(workspace-relative, gitignored, inspectable from the IDE):

```text
./tmp/visual/<short-task-name>/01-signin.png
./tmp/visual/<short-task-name>/02-assessment.png
```

Pass `filePath:` to `take_screenshot` so the image lands on disk and you can
`Read` it back as an image. Never write screenshots to a tracked path; avoid the
absolute `/tmp/` (outside the workspace, harder to inspect). This is separate
from `tmp/screenshots/...`, which the `SCREENSHOTS=1` system-test path owns.

## Workflow / tool tips

- `new_page(url:)` opens a tab. A fresh headless-shell has none — calling
  `navigate_page` first errors with *"No page selected."*
- **Prefer `take_snapshot` over `take_screenshot`** — the snapshot lists elements
  with `uid`s you pass to `click`/`fill`. Re-snapshot after every navigation;
  uids are per-snapshot. **Except on the edit-mode explorer**, where a snapshot
  (and a `wait_for`) is large enough to end the session — see the delegation
  notes above.
- `fill_form` fills multiple fields in one call (faster, fewer turns) — use it
  for the login form.
- `wait_for(text: [...])` to sync on the destination before asserting/clicking
  — except on the edit-mode explorer, where it returns the oversized tree too;
  poll with `evaluate_script` there.
- **`list_console_messages(types: ["error"])` after interactions** — surfaces
  JS/Turbo errors a snapshot won't show (this is how the Turbo-frame bug below
  was confirmed).
- `take_screenshot(filePath: "./tmp/visual/<task>/NN.png")` to save visual
  evidence — workspace-relative, never the absolute `/tmp/` (see *Screenshot
  paths*).
- **`evaluate_script` for cheap structural checks** — computed styles, scroll
  dimensions, presence of text, hidden state. Don't screenshot to answer "did the
  rating pill update?"; read the DOM.

## Gotchas learned

- **Always click the real path, don't just `navigate_page` to the destination.**
  Driving the actual link/button surfaces bugs a direct navigation hides — most
  notably the lazy-Turbo-Frame "Content missing" trap (links inside a frame need
  `data-turbo-frame="_top"`), which is how that bug was found this session. The
  rule itself lives in [phlex-views.md → Turbo Frames](phlex-views.md).
- **CDP/Selenium `.text` reflects CSS `text-transform`.** An eyebrow styled
  `uppercase` reports `UPPERCASE` text — `wait_for`/assertions must match the
  rendered case (or key off an untransformed element like a link label).
- **A bare `rails server` serves stale Tailwind CSS for brand-new views.**
  Tailwind v4 JIT only includes utilities already used somewhere at build time,
  so a view added after the last build renders with any *new-to-the-bundle*
  classes silently missing — invisible tracks/dots/bars that look like a layout
  bug (bit the calibration overview AND drill-in passes). System tests don't
  catch it (they build fresh CSS). Start the server with `bin/dev` (runs the
  watcher), or run `bin/rails tailwindcss:build` after adding/editing views
  before judging screenshots.
- **`resize_page` alone never activates `pointer-coarse:`.** Resizing to a
  phone-sized viewport changes only CSS dimensions — the `pointer` media
  feature does not move, so Tailwind `pointer-coarse:` affordances (e.g.
  always-visible kebab triggers) won't show. To verify touch-only behaviour,
  use `emulate` with a touch viewport string
  (`viewport: "375x812x2,mobile,touch"`), which flips
  `matchMedia('(pointer: coarse)')` to true.
- **Headless-shell reports `hover: none` — so a hover-revealed control never
  appears under `hover()`.** Measured on the `chrome-debug` container
  (Chrome 151 headless-shell): `hover: none`, `any-hover: none`, and
  `pointer: none` — *neither* `fine` nor `coarse`, so a `pointer-fine:` rule
  is as inert as a `pointer-coarse:` one. The trap is that the CSS `:hover`
  *pseudo-class* still matches perfectly well; what doesn't match is the
  **media query Tailwind v4 wraps every `hover:` / `group-hover:` utility in**
  — the built stylesheet emits one `@media (hover:hover){…}` block holding all
  of them. So `hover()` over a pencil, kebab or "Discuss" bubble that is
  revealed by a Tailwind hover utility changes nothing on screen, and a
  screenshot taken after it "proves" the control is missing. Two consequences:
  - **Verify the reveal structurally, not visually** — `evaluate_script` the
    computed style / `matches(':hover')` state, or dispatch a JS click
    (`el.click()`) straight at the control and check what it did. The system
    tests are the place that pins hover behaviour anyway (testing.md's
    JS-dispatch helpers exist for the same reason).
  - **Hand-written `:hover` CSS is unaffected.** The explorer's hover-cluster
    rule (`[data-hover-cluster="row"]:hover [data-cluster~="row"]`, §11a of
    framework-explorer.md) is plain CSS in `application.css`, outside any
    media query, so it *does* respond to `hover()`. Which mechanism a control
    uses decides whether the browser pass can see it — check before concluding
    the UI is broken.
  There is no `emulate` string that reports `hover: hover` on headless-shell,
  so the desktop reveal has no visual-pass verification path at all; the touch
  collapse does, via the `pointer: coarse` emulation above.
- **`performance.getEntriesByType("navigation")[0]` is stale after a Turbo
  Drive visit.** Turbo replaces the body without a document navigation, so the
  entry keeps describing whichever URL the tab loaded first — its `name`,
  `transferSize` and `decodedBodySize` all belong to that document, not the
  one on screen. Reading it after clicking through the app silently measures
  the wrong page (and reports the same bytes for every subsequent
  measurement). To size a document, read the **network request** instead —
  `list_network_requests` / `get_network_request`, or a signed-in
  `curl -w '%{size_download}'` from the app container, which is also what the
  payload numbers in framework-explorer.md's Lesson 23 were taken with.
- **`handle_dialog` can accept a `data-turbo-confirm` dialog and still lose the
  submit.** Seen on the assessment "Start alignment" button: `click` →
  `handle_dialog(accept)` reported success twice, yet no POST ever left the
  browser (`list_network_requests` showed none) — the same
  confirm-vs-automation race testing.md's `auto_confirm` exists for. Do what
  that helper does: `evaluate_script` `window.confirm = () => true`, then
  dispatch the button's own `.click()`, and prove the write landed (the
  live-status region, a status pill, or the network log) before screenshotting.
- **Seeded tenant state persists across sessions.** The `me&u` seed tenant
  accumulates assessment state (cycles, ratings, evidence, alignment) as you
  drive flows. A verification run that assumes a clean slate (an unrated
  assessment, no open cycle) must reset first, e.g.:
  `bin/rails runner 'ActsAsTenant.with_tenant(Tenant.find_by(slug: "meandu")) { ... }'`
  scoped to the person/framework under test. Don't assert "fresh" UI against a
  tenant another session already mutated.

## Scope — required pass, never a substitute for coverage

The Chrome MCP pass is **required** for every front-end change and is also the
right tool for exploration and bug repro. What it is **not** is where coverage
lives: it runs only in your turn, never in CI. So:

- **Every behaviour — new or fixed — must be represented by a Minitest system
  test** (Capybara + Selenium), at both viewports when responsive. That suite is
  the source of truth and the only thing CI guards. The `data-turbo-frame="_top"`
  fix, for instance, is pinned by a Home→cohort click-through in
  `test/system/assessment_cycles/cohort_system_test.rb` — the Chrome MCP session
  found it; the system test keeps it found.
- **The visual pass is additional, not alternative.** "I verified it in Chrome
  MCP" never discharges the obligation to write/maintain the system test, and a
  green system test never discharges the obligation to lay eyes on the change
  before marking it done. A front-end change needs both.
- **When you can't run the pass** (no server allowed, the browser won't connect), the change
  isn't done. Run what still runs (`bin/rubocop`, the guard tests, a component render), then
  hand off with the pass listed as owed, naming the screens, themes and viewports to check.
  Never report a front-end change as verified on tests alone.

## UX quality skill (`/ux-quality`)

The vendored [`ux-quality` skill](../../.claude/skills/ux-quality/SKILL.md) carries the
UX/WCAG 2.2 AA criteria for three lifecycle points: `build` (defaults while
writing UI), `spec-review` (UX gaps in a spec/plan before code exists), and
`assess` (adversarial browser-driven review — deeper than, and additional to,
the mandatory Chrome MCP pass this guide describes; use it for UX/accessibility sign-off of a
whole surface, not per-change verification). The skill is host-agnostic and
resolves this repo via its discovery contract — answers live here, not in the
skill (its portability rule forbids host facts in `.claude/skills/ux-quality/`):

- **Design system**: the Kit, Shared and Shell layers in `app/components/`, colour roles in
  `app/assets/tailwind/theme/`, and the rules in [phlex-views.md](phlex-views.md),
  [theming.md](theming.md) and [tailwindcss.md](tailwindcss.md).
- **Component catalogue**: [phlex-views.md → Which Kit component](phlex-views.md#which-kit-component)
  maps a job to a component; [`app/components/README.md`](../../app/components/README.md) shows
  each one in use; Lookbook (`/lookbook`) renders every state.
- **Conformance checks**: the guard tests in [theming.md → The guard tests](theming.md#the-guard-tests)
  and `bin/rubocop`. Run both on the files you change.
- **Theme matrix**: Default, Bento and Custom, each in light and dark, plus the stress tenant
  ([theming.md → Checking your work](theming.md#checking-your-work)).
- **Stricter house rules**: every `Kit::Button` takes a tap across 44px by default, and other key
  actions on touch screens aim for 44px; design direction can opt out with `compact: true`, above
  AA's 24px floor ([phlex-views.md → Touch targets](phlex-views.md#touch-targets)). Report a miss
  as a house-rule finding, not a WCAG failure.
- **Voice and vocabulary**: the text rules in the root `AGENTS.md`, and
  [the glossary](../02-glossary.md) for the product's names.
- **App URL / login / seeded-data control**: *Reaching the app*
  (`http://rails-app:6600` in the devcontainer, `http://localhost:6600` in a
  Claude Code cloud session), *Signing in* (the Rails-credentials admin) and the
  seeded-tenant caveat under *Gotchas learned*, above.
- **Browser driving**: the `chrome-driver` agent (`.claude/agents/chrome-driver.md`)
  — use it, not the skill's bundled dormant `ux-driver`.
- **Screenshot home**: `tmp/visual/<task>/` (gitignored).

Re-vendor from `mr-yum/connect` `.claude/skills/ux-quality/` to pick up upstream
improvements (last synced: `4aa21f8` — connect#137, which upstreamed all of this
repo's fixes, so the two trees are identical as of that merge). Since then this repo is ahead: discovery also resolves the component catalogue, conformance checks, theme matrix and stricter house rules, and build mode picks from the catalogue, skips code marked as debt, and runs the checks first. Upstream those to connect. Generic fixes
made here must be contributed upstream in the same round-trip; never edit the
vendored files with GrowthOS-specific facts — put those in this guide or
another under `docs/guidelines/`.

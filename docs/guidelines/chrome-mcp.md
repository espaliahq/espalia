# Chrome MCP — Manual UI Validation

> Read this when: driving the running app in a real browser via the
> `chrome-devtools` MCP — exploratory validation of a new front-end flow, or
> reproducing a user-reported UI bug. This **complements** system tests; it does
> not replace them. Encode anything you find as a Minitest system test (CI runs
> those; it does not run the MCP).

## How it's wired (devcontainer)

- Claude Code runs in the **`rails-app`** container. The browser is a **separate
  `chrome-debug`** service (`chromedp/headless-shell`) exposing CDP — see
  [.devcontainer/compose.yaml](../../.devcontainer/compose.yaml).
- [`.mcp.json`](../../.mcp.json) points `chrome-devtools-mcp` at
  **`http://localhost:9222`**.
- [`.devcontainer/start-chrome-cdp-proxy.sh`](../../.devcontainer/start-chrome-cdp-proxy.sh)
  (run by `postStartCommand` on every container start) launches a **socat
  forwarder** `127.0.0.1:9222 → chrome-debug:9222`. `socat` is installed via
  [.devcontainer/Dockerfile](../../.devcontainer/Dockerfile).

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

## Reaching the app — use `rails-app:3000`, not `localhost`

The browser runs in the `chrome-debug` container, so **`localhost` there is
chrome-debug, not the app.** Navigate to **`http://rails-app:3000/`** (`rails-app`
is the compose service name; the dev server binds `0.0.0.0`). Start the server
with `bin/dev` if nothing answers on `:3000`.

## Signing in

Credentials live in Rails credentials — never hardcode them. Fetch the seeded
global admin:

```bash
bin/rails runner 'a = Rails.application.credentials.dig(:admin, :user_1); puts a.email; puts a.password'
```

Then fill the Devise form (`Email`, `Password`) and submit. The seeded admin is a
global admin in the `me&u` tenant, so it can reach every surface.

## Workflow / tool tips

- `new_page(url:)` opens a tab. A fresh headless-shell has none — calling
  `navigate_page` first errors with *"No page selected."*
- **Prefer `take_snapshot` over `take_screenshot`** — the snapshot lists elements
  with `uid`s you pass to `click`/`fill`. Re-snapshot after every navigation;
  uids are per-snapshot.
- `fill_form` fills multiple fields in one call (faster, fewer turns) — use it
  for the login form.
- `wait_for(text: [...])` to sync on the destination before asserting/clicking.
- **`list_console_messages(types: ["error"])` after interactions** — surfaces
  JS/Turbo errors a snapshot won't show (this is how the Turbo-frame bug below
  was confirmed).
- `take_screenshot(filePath: "/tmp/...")` to save visual evidence.

## Gotchas learned

- **Links inside a lazy Turbo Frame need `data-turbo-frame="_top"`.** Content
  rendered in its own `turbo_frame_tag(name, src:)` (e.g. a Home dashboard card)
  will try to load a plain navigation link *into that frame*; if the destination
  page has no matching `<turbo-frame id=name>`, Turbo replaces the frame with
  **"Content missing"** and logs an error. Manual MCP clicking catches this;
  a system test that `visit`s the destination path directly does **not**. Always
  exercise the real click path, and add `data: { turbo_frame: "_top" }` to
  navigation links inside frames.
- **CDP/Selenium `.text` reflects CSS `text-transform`.** An eyebrow styled
  `uppercase` reports `UPPERCASE` text — `wait_for`/assertions must match the
  rendered case (or key off an untransformed element like a link label).

## Scope

Exploratory validation and bug repro only. Regressions you find must be pinned
with a Minitest **system test** (Capybara + Selenium) so CI guards them — e.g.
the `data-turbo-frame="_top"` fix is covered by a Home→cohort click-through in
`test/system/assessment_cycles/cohort_system_test.rb`.

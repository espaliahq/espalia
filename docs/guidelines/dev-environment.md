# Development Environment

> Read this when: setting up, running or debugging the app outside the usual devcontainer flow — a Claude Code cloud session, a second worktree, the macOS host — or measuring performance in development. The devcontainer itself is the documented path; [AGENTS.md](../../AGENTS.md) has its commands.

## Cloud sessions: `bin/cloud-setup`, not the devcontainer

**A Claude Code cloud session runs the app natively, through `bin/cloud-setup`.** The
devcontainer would rebuild its Rails image and start eight containers every session. The
script takes about nine minutes from a cold container and six seconds once everything is in
place. The environment's setup script runs it as root from the checkout; run it again by hand
to restart anything that has stopped. It provides:

- **Ruby from `.ruby-version`**, compiled by ruby-build into `/opt/rubies/<version>`. Bundler
  insists on the exact patch, and the image carries Ruby 3.3, so nothing else will do.
- **Postgres from CI's `postgres:<major>` image tag**, using the image's own Ubuntu cluster on
  `localhost:5432`, with the `postgres`/`postgres` login `database.yml` expects.
- **System tests on the local-Chrome branch** of `ApplicationSystemTestCase`, the one CI runs:
  `CAPYBARA_SERVER_PORT` stays unset, so one worker drives the preinstalled Playwright
  Chromium. The script fetches the chromedriver that matches it (the image's is newer, and
  Selenium Manager cannot reach its version index) and writes a `/usr/bin/google-chrome`
  wrapper that adds `--no-sandbox`, which Chrome needs to run as root.
- **A headless Chromium on `localhost:9222`**, where `.mcp.json` already points the
  `chrome-devtools` MCP.
- **The egress proxy's CAs in Chrome's NSS store**, so the browser can load anything off-host.
- **The gems, the Tailwind build, the test database**, and the development database, seeded.

**The tools reach the session through `/root/.local/bin`.** A session's shell takes its `PATH`
from the Claude process, not from `~/.bashrc`, and `/root/.local/bin` is already on it ahead of
the image's Ruby and chromedriver. The script symlinks Ruby, Bundler, the gems' executables and
the chromedriver there.

**The environment provides three things.** Network access to the hosts the script downloads
from: `cache.ruby-lang.org` (Ruby), `storage.googleapis.com` (chromedriver), `rubygems.org`
(gems), and `archive.ubuntu.com` and `security.ubuntu.com` (any missing system package). `LANG=C.UTF-8`, without which
Ruby reads files as US-ASCII. `ESPALIA_MASTER_KEY` (or the older `GROWTHOS_MASTER_KEY`) is optional: `db:prepare` seeds the Null Island demo tenant with no
secrets at all (synthetic people on @nullisland.example). With the key set, the credentials
file's other entries decrypt as usual; the seed itself no longer reads it.

**A cloud session's Chromium never settles `navigator.clipboard.writeText` without a user
gesture**, so a system test that copies must click for real — see
[testing.md → Copying to the clipboard](testing.md#copying-to-the-clipboard-click-for-real).

Where the app runs in a cloud session, and how to start it, is in the root
[AGENTS.md](../../AGENTS.md) (it loads in every session, so it is the one copy).

## A second worktree

**A second worktree needs its own database and ports, and the host is `postgres`, not `localhost`.** Prefix every command with `DATABASE_URL=postgresql://postgres:postgres@postgres/<name>` (plus `CAPYBARA_SERVER_PORT` for system tests; parallel workers derive `<name>-N` and `port+N`) and run the dev server on another port with `-b 0.0.0.0`, so the browser container reaches `http://rails-app:<port>`. Clone the seeded dev database with `createdb -h postgres -U postgres -T growth_os_development <name>` — `pg_dump` in the devcontainer is v15 against a v16 server and refuses. The template copy **fails while any other session is connected to the source** (`source database "growth_os_development" is being accessed by other users`), and the shared dev server makes that a normal state: stop the dev server on port 6600 and any other agent using the database first, then clone. If you cannot clear the source, build the clone from scratch instead: `PGPASSWORD=postgres createdb -h postgres -U postgres <name> </dev/null`, then `bin/rails db:schema:load` and `bin/rails db:seed` under the worktree's `DATABASE_URL`. **Never run `bin/rails development:precommit` from a second worktree.** Its `db:test:prepare` step reads the test config from `database.yml`, which hardcodes `growth_os_test`; `DATABASE_URL` only overrides the *current* environment, so the task purges and reloads the shared test database with the worktree's schema while another session may be using it (seen on 2026-10-20 from PR #557: a later run failed with "database growth_os_test is being accessed by other users", and the earlier, successful run had already done the damage). Run the steps individually instead, every one under `RAILS_ENV=test DATABASE_URL=postgresql://postgres:postgres@postgres/<name>_test` (create that database once with `bin/rails db:prepare` under the same variables): `development:erblint`, `development:rubocop`, `development:brakeman`, `development:bundler_audit`, `development:importmap_audit`, `zeitwerk:check`, `bin/rails test`, `bin/rails test:system` with `CAPYBARA_SERVER_PORT` set, then `bin/rails contract:consumer` and `bin/rails contract:provider` (the feedback exchange's Pact checks). The relabel trick an earlier version of this section suggested (`db:environment:set`) does not help, because the problem is which database the step targets, not its environment label. Four parallel worktrees hit the first symptom on 2026-10-19 (PRs #523, #524, #526, #527); the root cause surfaced a day later.

**Set `PGPASSWORD=postgres` before `createdb` or `psql` in a
non-interactive shell, and redirect stdin from `/dev/null` for a command
that reads nothing from it (`createdb`, `psql -c`, `psql -f`). A `psql`
fed SQL on stdin keeps its stdin. `pg_isready` needs no password.** Without the
password the client prompts; in an agent shell with no terminal the prompt
reads an empty line, fails, and a loop re-prompts hundreds of times a
second. Three worktree clones done that way on 2026-10-20 left 28,000
sockets in `TIME_WAIT` and every connection to `postgres` failing with
`Cannot assign requested address` for the next minute, including the ones
that had the password right. `pg_isready` reporting `no response` while the
server is fine is the tell; it clears on its own once the sockets expire.

**In a worktree nested inside the main checkout (Claude Code's
`.claude/worktrees/<name>`), a bare `rubocop` also runs the main checkout's
custom cops.** Without `--config`, RuboCop reads `AllCops/Exclude` from the
outermost `.rubocop.yml` it finds, and loading that file executes its `require:`
list, so the main checkout's `lib/rubocop/cop/**` loads after the worktree's and
redefines each cop. The tell is a run of `already initialized constant
RuboCop::Cop::…` warnings naming both paths. It hits `bundle exec rubocop` and
editor integrations; `bin/rubocop`, and so precommit, passes `--config` and is
immune. When you change a custom cop in a nested worktree, lint with
`bin/rubocop` or add `--ignore-parent-exclusion`.

## A system run where every test errors with "tab crashed"

**In the devcontainer, hundreds of `Selenium::WebDriver::Error::WebDriverError: tab crashed` errors can mean the remote Selenium Grid's Chromium nodes ran out of memory — confirm that before treating it as infrastructure.** This applies to the devcontainer path, where `SELENIUM_HOST=selenium-hub` sends tests to the four `selenium-node-*` containers (`.devcontainer/compose.yaml`, 1 GB shm each); cloud sessions run a local Chromium instead (see above) and don't share this failure mode. Those containers share the OrbStack VM with every other session's containers, and when the VM is near its limit Chromium's renderers are killed mid-run: every later test then errors in `sign_in_as` or the first `fill_in`, and the summary reads like `720 runs, 280 assertions, 0 failures, 685 errors`. Treat it as memory pressure only with evidence: `free -h` shows the VM near its limit (~13 of 15 GB used, swap full, during the 5 Nov 2026 runs), the errors start at a sign-in rather than at your change's screens, and a re-run of `bin/rails test:system` once memory recovers is clean. A Grid status check (`curl -s http://selenium-hub:4444/status`: `ready: true`, four nodes `UP`) tells you the nodes are back, not why a renderer died. Anything that still fails on the re-run is a real failure.

## A checkout without `config/master.key`

**The seeded dev admin is `admin@example.com` / `password123`** — created by
`SeedAdmin` with no credentials file involved. `SEED_ADMIN_EMAIL` /
`SEED_ADMIN_PASSWORD` override it in any environment (that pair is also how a
production first deploy bootstraps its admin; `bin/rails admin:create
EMAIL=… PASSWORD=…` does it after the fact).

Development derives its ActiveRecord encryption keys from the local
`secret_key_base` (`tmp/local_secret.txt`) when the credentials file can't be
decrypted (`config/environments/development.rb`). Two consequences:

- `bin/setup` and the app work with no secrets at all — nothing to fetch
  before a first run.
- **Those keys live in `tmp/`.** Wiping it (`git clean -dfx`, a rebuilt
  volume) while keeping the database makes every encrypted tenant column
  (`hris_credentials`, `ai_credentials`, …) raise
  `ActiveRecord::Encryption::Errors::Decryption` on read. Restore the old
  `tmp/local_secret.txt` if you have it — that keeps everything readable.
  Otherwise `bin/rails db:reset` re-seeds, losing whatever was created after
  the last seed. A checkout **with** `master.key` is immune: its keys come
  from the credentials file.

## Stopping `bin/dev` or a test run from a script

`pkill -f "bin/dev"` (or any `pkill -f` whose pattern appears in your own
command line) matches the shell that runs it and kills itself — exit 144,
work half done. Kill by PID instead: `pgrep -x overmind`, check the state,
`kill <pid>`. A `Z`/`<defunct>` result is already dead and unkillable;
ignore it. After killing a test run, clear stale `growth_os_test` backends
before the next one (see the killed-test-run note in testing lore): a
leftover `idle in transaction` backend makes the next run hang before it
prints anything.

## The macOS host

**Running on the macOS host instead of the devcontainer: parallel test workers hang, and a stray user gem directory breaks Bundler.** `bin/rails test` with the default `parallelize(workers: :number_of_processors)` forks workers that never print a dot on macOS — with or without `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` — so run with `PARALLEL_WORKERS=1` (the whole non-system suite is a few minutes single-process). And a `~/.gem/ruby/<abi>` directory on the gem path can make the pinned Ruby's Bundler fail to load with an unrelated-looking `NoMethodError` deep in rubygems; point `GEM_HOME`/`GEM_PATH` at the Ruby's own gem directory before `bundle install`. Homebrew's Postgres ships without the `postgres` role `database.yml` expects (`CREATE ROLE postgres WITH SUPERUSER LOGIN PASSWORD 'postgres'`), and `DB_HOST=localhost` replaces the compose service name. Two mobile-viewport system tests fail on the host's Chrome whatever the branch (`notifications_system_test.rb` "keep the dropdown panel fully on-screen" and `framework_explorer_system_test.rb` "close mobile role tree overlay when clicking outside" — the window does not shrink to 375 px there); read them against `main` in a worktree before blaming a change, and let CI be the verdict. The devcontainer remains the documented path; this is for when it isn't running.

## `gh` in the devcontainer

**`gh` unauthenticated in the devcontainer? Re-run the feature hook, don't `gh auth login`.** The `gh-auth-from-host` feature bridges the host's forwarded git credential into `gh` only on `postAttachCommand`; it warns and exits 0 when the host offers nothing at that instant, and a long-lived VS Code connection never re-attaches, so one silent miss at container creation leaves `gh` logged out for the container's lifetime. Fix in place with `sh /usr/local/share/gh-auth-from-host/refresh.sh`. A container-local `gh auth login` shadows the bridge and rots when the host token rotates.

## CodeRabbit CLI in the devcontainer

**CodeRabbit CLI auth is per-machine: log in interactively inside each container, and again after every rebuild.** Since 0.9 a browser sign-in's token is bound to the machine that logged in, so a host credential never serves the container — a `~/.coderabbit` bind mount was tried ([PR #684](https://github.com/mr-yum/growth-os/pull/684)) and reverted, because shared state just makes host and container overwrite each other's single credential slot. The symptoms of a foreign or stale credential are "Provider identity could not be verified" or `credentials_unavailable` ("no token is available" in `coderabbit doctor`), even though `auth.json` claims an `expiresAt` decades away; a self-update of the CLI (it updates itself on launch; 0.4 → 0.9 here) invalidates the session the same way. Fix with `coderabbit auth login` in the environment that will run the reviews. For headless use CodeRabbit offers Agentic API keys (`coderabbit auth login --api-key`), deliberately not adopted here.

## A container rebuild wipes `/tmp`

**Anything that must survive a devcontainer rebuild goes in the repo's
gitignored `tmp/`, never under `/tmp`.** The container's `/tmp` — including
agent scratchpad directories — is destroyed on every rebuild, while the
workspace is a mounted volume and persists. A set of scripts whose only copy
lived in a scratchpad was lost this way and had to be reconstructed from a
session transcript. If a scratchpad file matters beyond the current session,
copy it to `tmp/<purpose>/` in the main checkout — not in a removable
worktree — or commit it, before the next rebuild or worktree removal.

## Measuring in development

**Never quote dev-mode timings from the first requests after a boot.** They run 2–3× slower than steady state (cold caches, first-time constant loading, GC). [#487](https://github.com/mr-yum/growth-os/issues/487) was filed saying a framework-tree preload cost 88 ms of a 134 ms build; warm, the whole build was 46 ms, and the fix saved 13 ms rather than ~70. Warm up first, then interleave old and new paths in one process (shuffle the order each iteration) and compare medians. Measure against seeded data in a cloned database (`createdb -h postgres -U postgres -T growth_os_development <name>`, then `DATABASE_URL=postgresql://postgres:postgres@postgres/<name>`), never by mutating the shared dev database.

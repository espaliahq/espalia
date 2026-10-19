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
Ruby reads files as US-ASCII. And `GROWTHOS_MASTER_KEY`, which the script writes to the gitignored `config/master.key` before
`db:prepare` seeds development. Tests never need it. The seed signs in the admin from
credentials and runs a live HiBob sync, so the cloud database holds real emails, as a local one
does (names are whimsified).

**A cloud session's Chromium never settles `navigator.clipboard.writeText` without a user
gesture**, so a system test that copies must click for real — see
[testing.md → Copying to the clipboard](testing.md#copying-to-the-clipboard-click-for-real).

**In a cloud session the app is at `http://localhost:6600`**, not `rails-app:6600`: the MCP
browser runs in the same container. Start it with `bin/rails server -p 6600`; `bin/dev` needs
Overmind, which the image lacks.

## A second worktree

**A second worktree needs its own database and ports, and the host is `postgres`, not `localhost`.** Prefix every command with `DATABASE_URL=postgresql://postgres:postgres@postgres/<name>` (plus `CAPYBARA_SERVER_PORT` for system tests; parallel workers derive `<name>-N` and `port+N`) and run the dev server on another port with `-b 0.0.0.0`, so the browser container reaches `http://rails-app:<port>`. Clone the seeded dev database with `createdb -h postgres -U postgres -T growth_os_development <name>` — `pg_dump` in the devcontainer is v15 against a v16 server and refuses; the template copy needs no open connections to the source.

## The macOS host

**Running on the macOS host instead of the devcontainer: parallel test workers hang, and a stray user gem directory breaks Bundler.** `bin/rails test` with the default `parallelize(workers: :number_of_processors)` forks workers that never print a dot on macOS — with or without `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` — so run with `PARALLEL_WORKERS=1` (the whole non-system suite is a few minutes single-process). And a `~/.gem/ruby/<abi>` directory on the gem path can make the pinned Ruby's Bundler fail to load with an unrelated-looking `NoMethodError` deep in rubygems; point `GEM_HOME`/`GEM_PATH` at the Ruby's own gem directory before `bundle install`. Homebrew's Postgres ships without the `postgres` role `database.yml` expects (`CREATE ROLE postgres WITH SUPERUSER LOGIN PASSWORD 'postgres'`), and `DB_HOST=localhost` replaces the compose service name. Two mobile-viewport system tests fail on the host's Chrome whatever the branch (`notifications_system_test.rb` "keep the dropdown panel fully on-screen" and `framework_explorer_system_test.rb` "close mobile role tree overlay when clicking outside" — the window does not shrink to 375 px there); read them against `main` in a worktree before blaming a change, and let CI be the verdict. The devcontainer remains the documented path; this is for when it isn't running.

## `gh` in the devcontainer

**`gh` unauthenticated in the devcontainer? Re-run the feature hook, don't `gh auth login`.** The `gh-auth-from-host` feature bridges the host's forwarded git credential into `gh` only on `postAttachCommand`; it warns and exits 0 when the host offers nothing at that instant, and a long-lived VS Code connection never re-attaches, so one silent miss at container creation leaves `gh` logged out for the container's lifetime. Fix in place with `sh /usr/local/share/gh-auth-from-host/refresh.sh`. A container-local `gh auth login` shadows the bridge and rots when the host token rotates.

## Measuring in development

**Never quote dev-mode timings from the first requests after a boot.** They run 2–3× slower than steady state (cold caches, first-time constant loading, GC). [#487](https://github.com/mr-yum/growth-os/issues/487) was filed saying a framework-tree preload cost 88 ms of a 134 ms build; warm, the whole build was 46 ms, and the fix saved 13 ms rather than ~70. Warm up first, then interleave old and new paths in one process (shuffle the order each iteration) and compare medians. Measure against seeded data in a cloned database (`createdb -T growth_os_development <name>`, then `DATABASE_URL=…/<name>`), never by mutating the shared dev database.

#!/usr/bin/env bash
# Post-start lifecycle hook. Step semantics live in lifecycle-steps.sh:
# every independent step runs even when an earlier one fails, failures are
# reported by name, and the hook still exits non-zero on any failure.
set -u
cd "$(dirname "$0")/.." || exit 1

PHASE="$(basename "$0" .sh)"
source "$(dirname "$0")/lifecycle-steps.sh"

# Independent tooling first — a database failure must not cost us the proxy.
# (gh auth is NOT here — the gh-auth-from-host feature owns it, per attach.
#  If gh is unauthenticated mid-session, re-run its hook by hand:
#  sh /usr/local/share/gh-auth-from-host/refresh.sh — see AGENTS.md Learnings.)
run_step "clear stale overmind socket" rm -f .overmind.sock
run_step "start chrome CDP proxy"      .devcontainer/start-chrome-cdp-proxy.sh
run_step "db:prepare"                  bin/rails db:prepare

finish_steps

#!/usr/bin/env bash
# Post-start lifecycle hook. Step semantics live in lifecycle-steps.sh:
# every independent step runs even when an earlier one fails, failures are
# reported by name, and the hook still exits non-zero on any failure.
set -u
cd "$(dirname "$0")/.."

PHASE="$(basename "$0" .sh)"
source "$(dirname "$0")/lifecycle-steps.sh"

# Independent tooling first — a database failure must not cost us the proxy.
run_step "clear stale overmind socket" rm -f .overmind.sock
run_step "start chrome CDP proxy"      .devcontainer/start-chrome-cdp-proxy.sh
run_step "db:prepare"                  bin/rails db:prepare

finish_steps

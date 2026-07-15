#!/usr/bin/env bash
# Runs every post-start step even when an earlier one fails, then reports
# a per-step summary. The previous inline `a && b && c` chain meant a
# failing `db:prepare` (e.g. Postgres not yet accepting connections) also
# took down the chrome-CDP proxy — two unrelated capabilities lost to one
# transient failure, silently.
#
# Exits non-zero when any step failed so the devcontainer UI still surfaces
# the failure — but only after every independent step has had its chance.
set -u
cd "$(dirname "$0")/.."

failed=()

run_step() {
  name="$1"; shift
  echo "── post-start: ${name}"
  if ! "$@"; then
    echo "✗ post-start step failed: ${name}" >&2
    failed+=("${name}")
  fi
}

# Independent tooling first — a database failure must not cost us the proxy.
run_step "clear stale overmind socket" rm -f .overmind.sock
run_step "start chrome CDP proxy"      .devcontainer/start-chrome-cdp-proxy.sh
run_step "db:prepare"                  bin/rails db:prepare

if ((${#failed[@]})); then
  echo "✗ post-start finished with failed step(s): ${failed[*]}" >&2
  exit 1
fi
echo "✓ post-start complete"

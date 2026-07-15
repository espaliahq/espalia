#!/usr/bin/env bash
# Runs every post-create step even when an earlier one fails, then reports
# a per-step summary. The previous inline `a && b && c` chain meant one
# transient failure (typically bin/setup racing a still-booting Postgres)
# silently skipped everything after it — the container came up without the
# claude CLI or the seeded ~/.claude.json and nothing said why.
#
# Exits non-zero when any step failed so the devcontainer UI still surfaces
# the failure — but only after every independent step has had its chance.
set -u
cd "$(dirname "$0")/.."

failed=()

run_step() {
  name="$1"; shift
  echo "── post-create: ${name}"
  if ! "$@"; then
    echo "✗ post-create step failed: ${name}" >&2
    failed+=("${name}")
  fi
}

# Independent tooling first — a database failure must not cost us the CLI.
run_step "clear stale overmind socket" rm -f .overmind.sock
run_step "seed ~/.claude.json"         .devcontainer/apply-claude-json-seed.sh
run_step "install claude CLI"          npm install -g @anthropic-ai/claude-code
run_step "bin/setup"                   bin/setup --skip-server

if ((${#failed[@]})); then
  echo "✗ post-create finished with failed step(s): ${failed[*]}" >&2
  exit 1
fi
echo "✓ post-create complete"

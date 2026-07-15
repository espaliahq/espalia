#!/usr/bin/env bash
# Post-create lifecycle hook. Step semantics live in lifecycle-steps.sh:
# every independent step runs even when an earlier one fails, failures are
# reported by name, and the hook still exits non-zero on any failure.
set -u
cd "$(dirname "$0")/.."

PHASE="$(basename "$0" .sh)"
source "$(dirname "$0")/lifecycle-steps.sh"

# Independent tooling first — a database failure must not cost us the CLI.
run_step "clear stale overmind socket" rm -f .overmind.sock
run_step "seed ~/.claude.json"         .devcontainer/apply-claude-json-seed.sh
run_step "install claude CLI"          npm install -g @anthropic-ai/claude-code
run_step "bin/setup"                   bin/setup --skip-server

finish_steps

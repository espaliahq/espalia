# shellcheck shell=bash
# Shared step-runner for the devcontainer lifecycle hooks (post-create.sh /
# post-start.sh). Sourced, not executed. Runs every registered step even when
# an earlier one fails — a transient failure (bin/setup or db:prepare racing
# a still-booting Postgres) must not silently skip independent tooling steps
# (claude CLI install, chrome CDP proxy) the way the old `a && b && c`
# lifecycle chains did.
#
# Usage (from a script in .devcontainer/):
#   PHASE="$(basename "$0" .sh)"
#   source "$(dirname "$0")/lifecycle-steps.sh"
#   run_step "step name" command args...
#   finish_steps   # prints the summary; exits non-zero if any step failed
#                  # (so the devcontainer UI still surfaces the failure)

failed=()

run_step() {
  name="$1"; shift
  echo "── ${PHASE}: ${name}"
  if ! "$@"; then
    echo "✗ ${PHASE} step failed: ${name}" >&2
    failed+=("${name}")
  fi
}

finish_steps() {
  if ((${#failed[@]})); then
    echo "✗ ${PHASE} finished with failed step(s): ${failed[*]}" >&2
    exit 1
  fi
  echo "✓ ${PHASE} complete"
}

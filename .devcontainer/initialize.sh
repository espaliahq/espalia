#!/bin/sh
# Runs on the host before `docker compose up`. Extracts the bearer value from
# OTEL_EXPORTER_OTLP_HEADERS (format: "Authorization=Bearer …") and writes it
# to .devcontainer/.env so the otelcol container (which is distroless and has
# no shell) can substitute ${UPSTREAM_AUTHORIZATION} directly.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
env_file="$script_dir/.env"

authorization=""
if [ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]; then
  authorization=$(printf %s "$OTEL_EXPORTER_OTLP_HEADERS" | sed -En 's/^[Aa]uthorization=//p')
fi

umask 077
printf 'UPSTREAM_AUTHORIZATION=%s\n' "$authorization" > "$env_file"

# Mirror the macOS Keychain Claude Code credential into ~/.claude/.credentials.json
# so the devcontainer (which can't reach Keychain) inherits the host's identity.
# No-op on non-macOS hosts. Silent if the Keychain entry is missing.
if [ "$(uname -s)" = "Darwin" ] && command -v security >/dev/null 2>&1; then
  claude_dir="$HOME/.claude"
  if [ -d "$claude_dir" ]; then
    if security find-generic-password -s "Claude Code-credentials" -w \
        > "$claude_dir/.credentials.json" 2>/dev/null; then
      chmod 600 "$claude_dir/.credentials.json"
    else
      rm -f "$claude_dir/.credentials.json"
      printf 'initialize.sh: Keychain entry "Claude Code-credentials" not found; skipping creds sync\n' >&2
    fi
  fi
fi

# Seed Linux-side Claude Code onboarding flags. ~/.claude.json (top-level file)
# is NOT in the bind mount and gets wiped on container rebuild, so Claude Code
# would otherwise re-run the first-run wizard every rebuild. We write a seed
# into the bind-mounted ~/.claude/ dir; postCreateCommand merges it in-container.
if [ -d "$HOME/.claude" ]; then
  umask 077
  printf '%s\n' '{"hasCompletedOnboarding":true,"hasAcknowledgedCostThreshold":true}' \
    > "$HOME/.claude/.devcontainer-claude-json-seed.json"
fi

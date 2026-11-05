#!/bin/sh
# Runs on the host before `docker compose up`. Mirrors the macOS Keychain
# Claude Code credential into the bind-mounted ~/.claude/ dir and seeds the
# Linux-side onboarding flags so the devcontainer's Claude CLI inherits the
# host's identity without re-running the first-run wizard.
#
# GitHub is deliberately NOT mirrored here: VS Code's git credential helper
# already relays the host's gh token into the container live, so the container
# needs no copy. The gh-auth-from-host feature (devcontainer.json) bridges that
# into gh on every attach.
set -eu

# Seed Linux-side Claude Code onboarding flags. ~/.claude.json (top-level file)
# is NOT in the bind mount and gets wiped on container rebuild, so Claude Code
# would otherwise re-run the first-run wizard every rebuild. We write a seed
# into the bind-mounted ~/.claude/ dir; postCreateCommand merges it in-container.
if [ -d "$HOME/.claude" ]; then
  umask 077
  printf '%s\n' '{"hasCompletedOnboarding":true,"hasAcknowledgedCostThreshold":true}' \
    > "$HOME/.claude/.devcontainer-claude-json-seed.json"
fi

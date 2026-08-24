#!/usr/bin/env bash
# Prints the path to axe.min.js: the invoking workspace's node_modules copy
# when present, otherwise a pinned version downloaded once into a user cache.
set -euo pipefail

AXE_VERSION="${AXE_VERSION:-4.10.3}"

if [ -n "${AXE_PATH:-}" ]; then
  [ -f "$AXE_PATH" ] || { echo "AXE_PATH set but not a file: $AXE_PATH" >&2; exit 1; }
  echo "$AXE_PATH"
  exit 0
fi

local_copy="node_modules/axe-core/axe.min.js"
if [ ! -f "$local_copy" ]; then
  local_copy="$(find . -maxdepth 4 -path '*/node_modules/axe-core/axe.min.js' -print -quit 2>/dev/null || true)"
fi
if [ -n "$local_copy" ] && [ -f "$local_copy" ]; then
  # Absolute path — consumers (e.g. a driver agent) may read it from a
  # different working directory than the one this script ran in.
  echo "$(cd "$(dirname "$local_copy")" && pwd)/$(basename "$local_copy")"
  exit 0
fi

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ux-quality"
cached="$cache_dir/axe-$AXE_VERSION.min.js"
if [ ! -s "$cached" ]; then
  mkdir -p "$cache_dir"
  tmp="$(mktemp "$cache_dir/.axe-$AXE_VERSION.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL --connect-timeout 10 --max-time 60 "https://cdn.jsdelivr.net/npm/axe-core@$AXE_VERSION/axe.min.js" -o "$tmp"
  # Reject 200-status intercept pages (TLS-inspecting proxies, portals): a JS
  # payload never starts with '<', and real axe-core carries its own marker —
  # the URL alone (echoed by block pages) must not satisfy the check.
  case "$(head -c 1 "$tmp")" in "<") echo "downloaded file looks like HTML, not axe-core" >&2; exit 1;; esac
  grep -q 'axe-core' "$tmp" || { echo "downloaded file does not look like axe-core" >&2; exit 1; }
  mv "$tmp" "$cached"
  trap - EXIT
fi
echo "$cached"

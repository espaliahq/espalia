#!/usr/bin/env bash
#
# Forwards localhost:9222 → chrome-debug:9222 inside the devcontainer.
#
# chrome-debug runs Google's chromedp/headless-shell which serves CDP
# over a socat proxy on :9222, but Chrome's HTTP server rejects any
# request whose `Host` header isn't `localhost` or an IP. Connecting
# directly to `chrome-debug:9222` sends `Host: chrome-debug:9222` and
# trips that guard. socat-as-proxy on this side bridges the gap:
# the MCP client connects to `localhost:9222`, the `Host` header is
# `localhost:9222`, socat forwards the raw TCP bytes (header intact)
# to chrome-debug, and Chrome accepts.
#
# Called by .devcontainer/devcontainer.json `postStartCommand` on every
# boot. Idempotent — kills any prior instance before starting fresh.

set -euo pipefail

LOG=/tmp/socat-chrome.log

# Reap any previous instance so we don't pile up listeners on 9222.
# pkill only SENDS the signal — wait for the prior socat to actually
# release the port before starting a new one, otherwise the new bind()
# races and fails with EADDRINUSE even with SO_REUSEADDR.
#
# The loop tries 10 times at 100ms intervals (1s budget). If a stale
# process is still holding the port after that, log a warning and let
# socat fail loudly — silently swallowing this would leave the user
# without a working proxy and no obvious hint why.
if pkill -f 'socat.*TCP-LISTEN:9222' >/dev/null 2>&1; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f 'socat.*TCP-LISTEN:9222' >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -f 'socat.*TCP-LISTEN:9222' >/dev/null 2>&1; then
    echo "warning: prior socat on :9222 didn't exit within 1s; new bind may fail" >&2
  fi
fi

# Detach into a NEW session/process group with setsid so the listener
# survives postStartCommand finishing. nohup + disown alone only ignore
# SIGHUP and clear the shell's job table — they leave socat in the hook's
# process group, which the devcontainer reaps when the hook returns, so the
# boot-time forwarder was being killed moments after it started. setsid moves
# socat into its own session (it reparents to init), so it outlives the hook.
setsid socat TCP-LISTEN:9222,fork,reuseaddr,bind=127.0.0.1 \
             TCP:chrome-debug:9222 \
    >"$LOG" 2>&1 &
disown
echo "started socat forwarder (pid $!) — logging to $LOG"

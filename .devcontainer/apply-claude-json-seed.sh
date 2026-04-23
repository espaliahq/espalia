#!/bin/sh
# Runs inside the devcontainer. Merges ~/.claude/.devcontainer-claude-json-seed.json
# (written by .devcontainer/initialize.sh on the host) into ~/.claude.json so the
# interactive CLI skips the first-run wizard after a rebuild.
set -eu

seed="$HOME/.claude/.devcontainer-claude-json-seed.json"
target="$HOME/.claude.json"

[ -r "$seed" ] || exit 0

python3 - "$seed" "$target" <<'PY'
import json, pathlib, sys
seed_path, target_path = map(pathlib.Path, sys.argv[1:3])
seed = json.loads(seed_path.read_text())
data = json.loads(target_path.read_text()) if target_path.exists() else {}
for k, v in seed.items():
    data.setdefault(k, v)
target_path.write_text(json.dumps(data))
PY
chmod 600 "$target"

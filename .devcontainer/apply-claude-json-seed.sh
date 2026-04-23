#!/bin/sh
# Runs inside the devcontainer. Merges ~/.claude/.devcontainer-claude-json-seed.json
# (written by .devcontainer/initialize.sh on the host) into ~/.claude.json so the
# interactive CLI skips the first-run wizard after a rebuild.
set -eu

seed="$HOME/.claude/.devcontainer-claude-json-seed.json"
target="$HOME/.claude.json"

[ -r "$seed" ] || exit 0

python3 - "$seed" "$target" <<'PY'
import json, os, pathlib, sys
seed_path, target_path = map(pathlib.Path, sys.argv[1:3])
seed = json.loads(seed_path.read_text())
data = json.loads(target_path.read_text()) if target_path.exists() else {}
for k, v in seed.items():
    data.setdefault(k, v)
# Atomic write: sibling tmp file, fsync, chmod, rename.
tmp_path = target_path.with_suffix(target_path.suffix + f".tmp.{os.getpid()}")
fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
try:
    with os.fdopen(fd, "w") as f:
        f.write(json.dumps(data))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, target_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass
    raise
PY

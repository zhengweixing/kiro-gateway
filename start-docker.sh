#!/usr/bin/env bash
# Standalone Docker launcher for kiro-gateway (kiro-cli login, no API key).
#
# What it does:
#   1. Substitutes ${VAR} references in kiro.env with values from com.env
#      (same logic as a local launch) and writes docker/kiro.rendered.env
#      (git-ignored, mode 600).
#   2. Mounts the kiro-cli data directory so the gateway reads and refreshes
#      the token stored by `kiro-cli login`.
#   3. Runs `docker compose up -d`.
#
# Configuration (environment variable, or a line in the git-ignored .env):
#   KIRO_ENV_DIR   Directory containing com.env and kiro.env
#                  (default: ./docker/env)
#   KIRO_CLI_DIR   kiro-cli data directory containing data.sqlite3
#                  (default: macOS ~/Library/Application Support/kiro-cli,
#                   otherwise ~/.local/share/kiro-cli)
#   HOST_PORT      Host port (default: 52380)
set -euo pipefail

GATEWAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$GATEWAY_DIR"

# Read a KEY=value line from .env without sourcing it (values may contain spaces).
dotenv_get() {
    [ -f .env ] || return 0
    { grep -E "^$1=" .env || true; } | tail -n1 | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'
}

KIRO_ENV_DIR="${KIRO_ENV_DIR:-$(dotenv_get KIRO_ENV_DIR)}"
KIRO_ENV_DIR="${KIRO_ENV_DIR:-$GATEWAY_DIR/docker/env}"

KIRO_CLI_DIR="${KIRO_CLI_DIR:-$(dotenv_get KIRO_CLI_DIR)}"
if [ -z "$KIRO_CLI_DIR" ]; then
    if [ "$(uname -s)" = "Darwin" ]; then
        KIRO_CLI_DIR="$HOME/Library/Application Support/kiro-cli"
    else
        KIRO_CLI_DIR="$HOME/.local/share/kiro-cli"
    fi
fi

for f in "$KIRO_ENV_DIR/com.env" "$KIRO_ENV_DIR/kiro.env"; do
    [ -f "$f" ] || { echo "Missing $f (set KIRO_ENV_DIR to the directory with com.env and kiro.env)" >&2; exit 1; }
done
[ -f "$KIRO_CLI_DIR/data.sqlite3" ] || { echo "Missing $KIRO_CLI_DIR/data.sqlite3 (run 'kiro-cli login' or set KIRO_CLI_DIR)" >&2; exit 1; }

export KIRO_ENV_DIR KIRO_CLI_DIR
export RENDERED="$GATEWAY_DIR/docker/kiro.rendered.env"

python3 - <<'PY'
import os, re, sys

env_dir, out_path = os.environ["KIRO_ENV_DIR"], os.environ["RENDERED"]

def unquote(val: str) -> str:
    val = val.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        return val[1:-1]
    return val

def parse(path: str):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            yield key.strip(), unquote(val)

# Values from com.env, then container-side overrides (paths/ports inside the container).
variables = dict(parse(os.path.join(env_dir, "com.env")))
variables["SERVER_PORT"] = "8000"
variables["KIRO_CLI_DB_FILE"] = "/home/kiro/.local/share/kiro-cli/data.sqlite3"

missing = set()
def substitute(val: str) -> str:
    def repl(m):
        name = m.group(1)
        if name not in variables:
            missing.add(name)
            return m.group(0)
        return variables[name]
    return re.sub(r"\$\{(\w+)\}", repl, val)

lines = []
for key, val in parse(os.path.join(env_dir, "kiro.env")):
    val = substitute(val)
    if "'" in val or "\n" in val:
        sys.exit(f"Unsupported character in value of {key}")
    lines.append(f"{key}='{val}'")  # single quotes: compose will not re-interpolate

# Keys defined only in com.env are passed through too (kiro.env wins on conflicts).
defined = {l.split("=", 1)[0] for l in lines}
for key, val in variables.items():
    if key not in defined:
        lines.append(f"{key}='{val}'")

if missing:
    sys.exit("Unresolved variables in kiro.env: " + ", ".join(sorted(missing)))

fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
print(f"Rendered {len(lines)} variables -> {out_path}")
PY

export HOST_PORT="${HOST_PORT:-52380}"
exec docker compose up -d "$@"

#!/usr/bin/env bash
# check-adapters.sh — validate every adapter in adapters/ (and ~/.config/pod/adapters/).
#
# For each *.toml that isn't a doc stub (leading-underscore files like _schema.toml are
# skipped, matching pod-adapter's loader), assert:
#   - it parses as TOML (python tomllib)
#   - it has a non-empty [agent].id
#   - it has a non-empty [launch].base_cmd
#
# Exits 0 only if EVERY checked adapter passes; non-zero on the first batch of failures
# (all failures are reported, not just the first). Suitable for CI.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTERS_DIR="${POD_ADAPTERS_DIR:-$REPO/adapters}"
USER_ADAPTERS="${POD_USER_ADAPTERS:-${XDG_CONFIG_HOME:-$HOME/.config}/pod/adapters}"

PY_BIN="$(command -v python3 2>/dev/null || true)"
[ -n "$PY_BIN" ] || { echo "check-adapters.sh: python3 required (>= 3.11 for tomllib)" >&2; exit 2; }

"$PY_BIN" - "$ADAPTERS_DIR" "$USER_ADAPTERS" <<'PY'
import glob, os, sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.stderr.write("check-adapters.sh: needs Python 3.11+ (tomllib)\n")
    sys.exit(2)

dirs = [d for d in sys.argv[1:] if d and os.path.isdir(d)]
if not dirs:
    sys.stderr.write("check-adapters.sh: no adapters directory found (%s)\n" % ", ".join(sys.argv[1:]))
    sys.exit(2)

checked = 0
failures = []

for d in dirs:
    for path in sorted(glob.glob(os.path.join(d, "*.toml"))):
        base = os.path.basename(path)
        if base.startswith("_"):          # _schema.toml etc. are docs, never loaded
            continue
        checked += 1
        try:
            with open(path, "rb") as f:
                data = tomllib.load(f)
        except Exception as e:
            failures.append("%s: does not parse as TOML (%s)" % (path, e))
            continue
        agent = data.get("agent") or {}
        launch = data.get("launch") or {}
        if not isinstance(agent, dict) or not agent.get("id"):
            failures.append("%s: missing or empty [agent].id" % path)
        if not isinstance(launch, dict) or not launch.get("base_cmd"):
            failures.append("%s: missing or empty [launch].base_cmd" % path)
        if path not in [f.split(":")[0] for f in failures]:
            print("ok    %s  (id=%s)" % (path, agent.get("id")))

if checked == 0:
    sys.stderr.write("check-adapters.sh: no adapter files to check (only doc stubs?)\n")
    sys.exit(2)

if failures:
    sys.stderr.write("\ncheck-adapters.sh: %d failure(s):\n" % len(failures))
    for f in failures:
        sys.stderr.write("  FAIL  %s\n" % f)
    sys.exit(1)

print("\ncheck-adapters.sh: all %d adapter(s) valid." % checked)
PY

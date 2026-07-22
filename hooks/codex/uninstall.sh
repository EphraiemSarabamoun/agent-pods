#!/usr/bin/env bash
# uninstall.sh — remove the agent-pods Codex hook entries that install.sh added,
# leaving every other hook intact. Atomic write; the prior file is backed up first.
#
# A hook command is "ours" only when it exactly matches a command this installer emits.
# After removing matching entries, any hook group left with zero hooks is dropped, and
# any event left with zero groups is dropped — so we don't leave empty scaffolding.
#
#   uninstall.sh [--hooks-file <path>]   remove pod hook entries from hooks.json
#   uninstall.sh --restore [<backup>]    restore hooks.json from a .pod-bak.* backup
#                                        (newest if <backup> omitted)
set -uo pipefail
POD_BIN="$(cd "$(dirname "$0")/../../bin" && pwd)"; . "$POD_BIN/_pod-paths.sh"

HOOKS_FILE=""; RESTORE=0; BACKUP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hooks-file)
      [ "$#" -ge 2 ] || { echo "uninstall.sh: --hooks-file requires a value" >&2; exit 2; }
      HOOKS_FILE="$2"; shift 2 ;;
    --restore)    RESTORE=1; shift
                  case "${1:-}" in --*|"") ;; *) BACKUP="$1"; shift ;; esac ;;
    -h|--help)
      echo "usage: uninstall.sh [--hooks-file <path>] [--restore [<backup>]]"
      echo "  Removes agent-pods Codex hook entries from hooks.json,"
      echo "  or restores it from a .pod-bak.* backup with --restore."
      exit 0 ;;
    *) echo "uninstall.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$HOOKS_FILE" ]; then
  if [ -n "${CODEX_HOME:-}" ]; then
    HOOKS_FILE="$CODEX_HOME/hooks.json"
  else
    HOOKS_FILE="$HOME/.codex/hooks.json"
  fi
fi

command -v python3 >/dev/null 2>&1 || { echo "uninstall.sh: python3 required" >&2; exit 1; }

# --- restore mode: copy a backup back over hooks.json ------------------------------
if [ "$RESTORE" = "1" ]; then
  if [ -z "$BACKUP" ]; then
    # newest .pod-bak.* sibling of hooks.json
    BACKUP="$(ls -1t "${HOOKS_FILE}".pod-bak.* 2>/dev/null | head -1)"
  fi
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] || { echo "uninstall.sh: no backup found to restore" >&2; exit 1; }
  cp -p "$BACKUP" "$HOOKS_FILE"
  echo "uninstall.sh: restored $HOOKS_FILE from $BACKUP"
  exit 0
fi

[ -f "$HOOKS_FILE" ] || { echo "uninstall.sh: $HOOKS_FILE does not exist — nothing to remove."; exit 0; }

python3 - "$HOOKS_FILE" "$POD_BIN" <<'PY'
import json, os, shutil, sys, tempfile, datetime

hooks_path, pod_bin = sys.argv[1], sys.argv[2]

awareness = os.path.join(os.path.dirname(pod_bin), "hooks", "claude-code", "pod-awareness.sh")
OWNED = {
    'bash "%s/pod-codex-state" idle' % pod_bin,
    'bash "%s" codex' % awareness,
    'bash "%s/pod-codex-state" busy user_prompt_submit' % pod_bin,
    'bash "%s/pod-mail-check" UserPromptSubmit' % pod_bin,
    'bash "%s/pod-codex-state" wait' % pod_bin,
    'bash "%s/pod-codex-state" busy' % pod_bin,
    'bash "%s/pod-codex-state" idle stop --json' % pod_bin,
    'bash "%s/pod-brief" boot' % pod_bin,
    'bash "%s/pod-brief" refresh UserPromptSubmit' % pod_bin,
    'bash "%s/pod-primer"' % pod_bin,
}
def is_ours(cmd):
    return isinstance(cmd, str) and cmd in OWNED

try:
    with open(hooks_path) as f:
        txt = f.read().strip()
    data = json.loads(txt) if txt else {}
    if not isinstance(data, dict):
        raise ValueError("not a JSON object")
except Exception as e:
    print("uninstall.sh: cannot parse %s (%s); refusing to touch it" % (hooks_path, e), file=sys.stderr)
    sys.exit(1)

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    print("uninstall.sh: no hooks to remove in %s." % hooks_path)
    sys.exit(0)

removed = []
for event in list(hooks.keys()):
    groups = hooks.get(event)
    if not isinstance(groups, list):
        continue
    new_groups = []
    for group in groups:
        if not isinstance(group, dict):
            new_groups.append(group)
            continue
        ghooks = group.get("hooks", [])
        if not isinstance(ghooks, list):
            new_groups.append(group)
            continue
        kept = []
        for h in ghooks:
            if isinstance(h, dict) and h.get("type") == "command" and is_ours(h.get("command")):
                removed.append("%s: %s" % (event, h.get("command")))
                continue
            kept.append(h)
        if kept:
            group["hooks"] = kept
            new_groups.append(group)
        # else: group emptied of our hooks AND had nothing else -> drop it
    if new_groups:
        hooks[event] = new_groups
    else:
        del hooks[event]

if not removed:
    print("uninstall.sh: no agent-pods Codex hooks found in %s — nothing to do." % hooks_path)
    sys.exit(0)

# back up the existing file before rewriting
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
backup = "%s.pod-bak.%s" % (hooks_path, stamp)
try:
    shutil.copy2(hooks_path, backup)
    print("uninstall.sh: backed up %s -> %s" % (hooks_path, backup))
except Exception as e:
    print("uninstall.sh: backup failed (%s); aborting" % e, file=sys.stderr)
    sys.exit(1)

# atomic write
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(hooks_path)), prefix=".hooks.", suffix=".tmp")
try:
    os.fchmod(fd, os.stat(hooks_path).st_mode & 0o777)
    with os.fdopen(fd, "w") as tf:
        json.dump(data, tf, indent=2)
        tf.write("\n")
    os.replace(tmp, hooks_path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise

print("uninstall.sh: removed %d pod hook(s) from %s:" % (len(removed), hooks_path))
for r in removed:
    print("  - " + r)
PY

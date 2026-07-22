#!/usr/bin/env bash
# uninstall.sh — remove the agent-pods Claude Code hook entries that install.sh added,
# leaving every other hook intact. Atomic write; the prior file is backed up first.
#
# A hook command is "ours" only when it exactly matches a command this installer emits.
# After removing matching entries, any hook
# group left with zero hooks is dropped, and any event left with zero groups is
# dropped — so we don't leave empty scaffolding behind.
#
#   uninstall.sh [--settings <path>]   remove pod hook entries from settings.json
#   uninstall.sh --restore [<backup>]  restore settings.json from a .pod-bak.* backup
#                                      (newest if <backup> omitted)
set -uo pipefail
POD_BIN="$(cd "$(dirname "$0")/../../bin" && pwd)"; . "$POD_BIN/_pod-paths.sh"

SETTINGS=""; RESTORE=0; BACKUP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --settings)
      [ "$#" -ge 2 ] || { echo "uninstall.sh: --settings requires a value" >&2; exit 2; }
      SETTINGS="$2"; shift 2 ;;
    --restore)  RESTORE=1; shift
                case "${1:-}" in --*|"") ;; *) BACKUP="$1"; shift ;; esac ;;
    -h|--help)
      echo "usage: uninstall.sh [--settings <path>] [--restore [<backup>]]"
      echo "  Removes agent-pods Claude Code hook entries from settings.json,"
      echo "  or restores it from a .pod-bak.* backup with --restore."
      exit 0 ;;
    *) echo "uninstall.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$SETTINGS" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
  else
    SETTINGS="$HOME/.claude/settings.json"
  fi
fi

command -v python3 >/dev/null 2>&1 || { echo "uninstall.sh: python3 required" >&2; exit 1; }

# --- restore mode: copy a backup back over settings.json --------------------------
if [ "$RESTORE" = "1" ]; then
  if [ -z "$BACKUP" ]; then
    # newest .pod-bak.* sibling of settings.json
    BACKUP="$(ls -1t "${SETTINGS}".pod-bak.* 2>/dev/null | head -1)"
  fi
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] || { echo "uninstall.sh: no backup found to restore" >&2; exit 1; }
  cp -p "$BACKUP" "$SETTINGS"
  echo "uninstall.sh: restored $SETTINGS from $BACKUP"
  exit 0
fi

[ -f "$SETTINGS" ] || { echo "uninstall.sh: $SETTINGS does not exist — nothing to remove."; exit 0; }

python3 - "$SETTINGS" "$POD_BIN" <<'PY'
import json, os, shutil, sys, tempfile, datetime

settings_path, pod_bin = sys.argv[1], sys.argv[2]

# Match only exact commands the installer owns. Substring matching can delete an
# unrelated command such as report-pod-state-metrics.
awareness = os.path.join(os.path.dirname(pod_bin), "hooks", "claude-code", "pod-awareness.sh")
OWNED = {
    'bash "%s"' % awareness,
    'bash "%s/pod-state" idle' % pod_bin,
    'bash "%s/pod-brief" boot' % pod_bin,
    'bash "%s/pod-primer"' % pod_bin,
    'bash "%s/pod-mail-check" UserPromptSubmit' % pod_bin,
    'bash "%s/pod-state" busy' % pod_bin,
    'bash "%s/pod-work"' % pod_bin,
    'bash "%s/pod-brief" refresh UserPromptSubmit' % pod_bin,
    'bash "%s/pod-auto-brief"' % pod_bin,
    'bash "%s/pod-last"' % pod_bin,
    'bash "%s/pod-state" wait' % pod_bin,
    'bash "%s/pod-state" busy posttool' % pod_bin,
}
def is_ours(cmd):
    return isinstance(cmd, str) and cmd in OWNED

try:
    with open(settings_path) as f:
        txt = f.read().strip()
    data = json.loads(txt) if txt else {}
    if not isinstance(data, dict):
        raise ValueError("not a JSON object")
except Exception as e:
    print("uninstall.sh: cannot parse %s (%s); refusing to touch it" % (settings_path, e), file=sys.stderr)
    sys.exit(1)

hooks = data.get("hooks")
if not isinstance(hooks, dict):
    print("uninstall.sh: no hooks to remove in %s." % settings_path)
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
    print("uninstall.sh: no agent-pods Claude Code hooks found in %s — nothing to do." % settings_path)
    sys.exit(0)

# back up the existing file before rewriting
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
backup = "%s.pod-bak.%s" % (settings_path, stamp)
try:
    shutil.copy2(settings_path, backup)
    print("uninstall.sh: backed up %s -> %s" % (settings_path, backup))
except Exception as e:
    print("uninstall.sh: backup failed (%s); aborting" % e, file=sys.stderr)
    sys.exit(1)

# atomic write
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(settings_path)), prefix=".settings.", suffix=".tmp")
try:
    os.fchmod(fd, os.stat(settings_path).st_mode & 0o777)
    with os.fdopen(fd, "w") as tf:
        json.dump(data, tf, indent=2)
        tf.write("\n")
    os.replace(tmp, settings_path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise

print("uninstall.sh: removed %d pod hook(s) from %s:" % (len(removed), settings_path))
for r in removed:
    print("  - " + r)
PY

#!/usr/bin/env bash
# install.sh — wire agent-pods' Claude Code lifecycle hooks into the user's Claude
# Code settings.json WITHOUT clobbering any existing hooks.
#
# Claude Code is one of the hook-integrated adapters: these hooks give it
# instant state dots on the pod strip, work-headline capture, startup pod-awareness,
# and pod-mail surfaced as additionalContext. The wiring:
#
#   SessionStart     -> pod-awareness.sh   (roster + stamp this window as claude-code)
#                       pod-state idle      (back at the prompt)
#                       pod-brief boot      (inject the pod journal tail)
#                       pod-primer          (role primer + operator memory)
#   UserPromptSubmit -> pod-mail-check UserPromptSubmit   (surface unread pod-mail)
#                       pod-state busy      (a turn started)
#                       pod-work            (capture the turn's work headline)
#                       pod-brief refresh   (delta of podmate changes + auto-journal)
#                       pod-auto-brief      (manager only: FULL AUTO stance for this turn)
#   Stop             -> pod-state idle      (turn finished)
#                       pod-last            (stamp the last-reply digest + transcript)
#   Notification     -> pod-state wait      (a permission/attention prompt)
#   PostToolUse      -> pod-state busy posttool  (rescue a stuck wait dot only;
#                       a one-read no-op on every ordinary tool call)
#
# Idempotent: a pod hook is added only if an identical command isn't already present,
# so re-running is safe. Existing non-pod hooks (e.g. a TTS Stop hook) are left intact.
# settings.json is backed up first and rewritten atomically (tempfile + os.replace).
#
# Hook commands use ABSOLUTE resolved paths under this repo's bin ($POD_BIN), so the
# wiring survives a relocated repo as long as the files stay where install.sh found them.
# If the repo DID move, re-running heals rather than accumulates: pod hook entries that
# point at a different checkout are pruned before the new group is appended.
set -uo pipefail
POD_BIN="$(cd "$(dirname "$0")/../../bin" && pwd)"; . "$POD_BIN/_pod-paths.sh"

# Build the awareness path from the PHYSICAL repo root that _pod-paths.sh just resolved,
# never from a logical `cd "$(dirname "$0")" && pwd`. Every other command below is built
# from $POD_BIN, which is symlink-resolved (`cd -P`); a logical $0 keeps whatever symlinked
# component the caller typed (macOS /tmp -> /private/tmp, an autofs $HOME, a symlinked
# ~/Developer). The two spellings then disagree, and uninstall.sh — which rebuilds this
# path from the physical $POD_BIN — could never match the string we wrote, stranding the
# awareness hook in settings.json forever.
AWARENESS="$POD_REPO/hooks/claude-code/pod-awareness.sh"

# --- resolve target settings.json -------------------------------------------------
SETTINGS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --settings)
      [ "$#" -ge 2 ] || { echo "install.sh: --settings requires a value" >&2; exit 2; }
      SETTINGS="$2"; shift 2 ;;
    -h|--help)
      echo "usage: install.sh [--settings <path>]"
      echo "  Wires agent-pods Claude Code hooks into settings.json."
      echo "  Default: \$CLAUDE_CONFIG_DIR/settings.json else ~/.claude/settings.json"
      exit 0 ;;
    *) echo "install.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$SETTINGS" ]; then
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
  else
    SETTINGS="$HOME/.claude/settings.json"
  fi
fi

command -v python3 >/dev/null 2>&1 || { echo "install.sh: python3 required" >&2; exit 1; }

# --- merge via python: back up, add only missing pod entries, atomic write --------
python3 - "$SETTINGS" "$POD_BIN" "$AWARENESS" <<'PY'
import json, os, shlex, shutil, sys, tempfile, datetime

settings_path, pod_bin, awareness = sys.argv[1], sys.argv[2], sys.argv[3]

# The pod hooks, per event. Each command is an absolute path under this repo's bin
# (or the awareness script). Order matters within an event group: state/awareness first.
WIRING = {
    "SessionStart": [
        'bash "%s"' % awareness,
        'bash "%s/pod-state" idle' % pod_bin,
        'bash "%s/pod-brief" boot' % pod_bin,
        'bash "%s/pod-primer"' % pod_bin,
    ],
    "UserPromptSubmit": [
        'bash "%s/pod-mail-check" UserPromptSubmit' % pod_bin,
        'bash "%s/pod-state" busy' % pod_bin,
        'bash "%s/pod-work"' % pod_bin,
        'bash "%s/pod-brief" refresh UserPromptSubmit' % pod_bin,
        'bash "%s/pod-auto-brief"' % pod_bin,
    ],
    "Stop": [
        'bash "%s/pod-state" idle' % pod_bin,
        'bash "%s/pod-last"' % pod_bin,
    ],
    "Notification": [
        'bash "%s/pod-state" wait' % pod_bin,
    ],
    "PostToolUse": [
        # rescue a stuck "wait" dot: a tool result mid-turn means the agent is working
        # again (e.g. a just-approved permission prompt). The posttool source makes
        # pod-state act ONLY when the state was wait — one read + exit otherwise, so
        # ordinary tool calls never pay a stamp or a redraw.
        'bash "%s/pod-state" busy posttool' % pod_bin,
    ],
}
TIMEOUTS = {
    'bash "%s"' % awareness: 10,
    'bash "%s/pod-mail-check" UserPromptSubmit' % pod_bin: 5,
    'bash "%s/pod-brief" boot' % pod_bin: 6,
    'bash "%s/pod-brief" refresh UserPromptSubmit' % pod_bin: 6,
    'bash "%s/pod-last"' % pod_bin: 5,
    'bash "%s/pod-primer"' % pod_bin: 6,
}
def timeout_for(cmd):
    return TIMEOUTS.get(cmd, 3)

# --- load (tolerate missing / empty / malformed-but-recoverable) ---
data = {}
existed = os.path.exists(settings_path)
if existed:
    try:
        with open(settings_path) as f:
            txt = f.read().strip()
        data = json.loads(txt) if txt else {}
        if not isinstance(data, dict):
            print("install.sh: %s is not a JSON object; refusing to touch it" % settings_path, file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print("install.sh: cannot parse %s (%s); refusing to touch it" % (settings_path, e), file=sys.stderr)
        sys.exit(1)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("install.sh: settings.hooks is not an object; refusing to touch it", file=sys.stderr)
    sys.exit(1)

def existing_commands(event):
    """Set of every hook command string already wired for this event (any matcher)."""
    out = set()
    for group in hooks.get(event, []) or []:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks", []) or []:
            if isinstance(h, dict) and h.get("type") == "command" and isinstance(h.get("command"), str):
                out.add(h["command"])
    return out

# --- structural ownership: recognize a pod hook baked with ANY path prefix ----------
# The wiring above bakes absolute paths, so a user who moves or re-clones the repo and
# re-runs this installer (exactly what README tells them to do) would otherwise end up
# with BOTH sets wired: the dead one keeps firing `bash "/gone/bin/pod-state" idle` on
# every event (bash exits 127, Claude Code surfaces a hook error) and no uninstaller run
# from the new location can reach it, because ownership was matched by exact string.
# So match on the SCRIPT instead: argv[1]'s basename, required to sit under a `bin/` or
# `hooks/claude-code/` parent. That is tight enough that an unrelated user command such
# as report-pod-state-metrics never matches, and loose enough to recognize our own
# entries from any prior checkout.
POD_BIN_SCRIPTS = {
    "pod-state", "pod-brief", "pod-primer", "pod-mail-check",
    "pod-work", "pod-auto-brief", "pod-last",
}

def pod_hook_script(cmd):
    """The pod script this hook command runs, or None when the command isn't ours."""
    if not isinstance(cmd, str):
        return None
    try:
        argv = shlex.split(cmd)
    except ValueError:
        return None                       # unbalanced quotes: not something we wrote
    if len(argv) < 2 or os.path.basename(argv[0]) not in ("bash", "sh"):
        return None
    path, parent = argv[1], os.path.dirname(argv[1])
    if os.path.basename(path) == "pod-awareness.sh":
        if os.path.basename(parent) == "claude-code" and \
           os.path.basename(os.path.dirname(parent)) == "hooks":
            return path
        return None
    if os.path.basename(path) in POD_BIN_SCRIPTS and os.path.basename(parent) == "bin":
        return path
    return None

# Entries pointing at THIS checkout are handled by the idempotent merge below; anything
# else is an orphan from a checkout that has moved, and gets pruned.
CURRENT_DIRS = {pod_bin, os.path.dirname(awareness)}

pruned = []
for event in list(hooks.keys()):
    groups = hooks.get(event)
    if not isinstance(groups, list):
        continue
    new_groups = []
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
            new_groups.append(group)
            continue
        kept = []
        for h in group["hooks"]:
            script = pod_hook_script(h.get("command")) \
                if isinstance(h, dict) and h.get("type") == "command" else None
            if script is not None and os.path.dirname(script) not in CURRENT_DIRS:
                pruned.append("%s: %s" % (event, h.get("command")))
                continue
            kept.append(h)
        if kept:
            group["hooks"] = kept
            new_groups.append(group)
        # else: the group held nothing but stale pod entries -> drop the empty scaffolding
    if new_groups:
        hooks[event] = new_groups
    else:
        del hooks[event]

added = []
for event, cmds in WIRING.items():
    have = existing_commands(event)
    missing = [c for c in cmds if c not in have]
    if not missing:
        continue
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        print("install.sh: settings.hooks.%s is not an array; refusing to touch it" % event, file=sys.stderr)
        sys.exit(1)
    # Append our missing entries as one new matcher-less group, so we never reorder or
    # mutate a user's existing groups (e.g. their TTS Stop hook stays first).
    groups.append({
        "hooks": [{"type": "command", "command": c, "timeout": timeout_for(c)} for c in missing]
    })
    added.extend(["%s: %s" % (event, c) for c in missing])

if not added and not pruned:
    print("install.sh: all agent-pods Claude Code hooks already present in %s — nothing to do." % settings_path)
    sys.exit(0)

# --- back up the existing file ---
if existed:
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup = "%s.pod-bak.%s" % (settings_path, stamp)
    try:
        shutil.copy2(settings_path, backup)
        print("install.sh: backed up %s -> %s" % (settings_path, backup))
    except Exception as e:
        print("install.sh: backup failed (%s); aborting" % e, file=sys.stderr)
        sys.exit(1)

# --- atomic write ---
# Write to the REALPATH, not the path we were handed: os.replace() acts on the link
# itself, so a dotfiles-managed settings.json (stow/chezmoi/yadm point ~/.claude/
# settings.json at a repo file) would be silently detached and replaced by a regular
# file — the dotfiles copy keeps being edited and never takes effect again. Resolving
# first also puts the tempfile on the real file's filesystem, which is what makes the
# rename atomic in the first place.
real_path = os.path.realpath(settings_path)
os.makedirs(os.path.dirname(real_path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real_path), prefix=".settings.", suffix=".tmp")
try:
    os.fchmod(fd, (os.stat(settings_path).st_mode & 0o777) if existed else 0o600)
    with os.fdopen(fd, "w") as tf:
        json.dump(data, tf, indent=2)
        tf.write("\n")
    os.replace(tmp, real_path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise

if pruned:
    print("install.sh: pruned %d pod hook(s) from a previous repo location in %s:" % (len(pruned), settings_path))
    for p in pruned:
        print("  - " + p)
if added:
    print("install.sh: wired %d pod hook(s) into %s:" % (len(added), settings_path))
    for a in added:
        print("  + " + a)
PY

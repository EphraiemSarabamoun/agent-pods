#!/usr/bin/env bash
# install.sh — wire agent-pods' Codex lifecycle hooks into the user's ~/.codex/hooks.json
# WITHOUT clobbering any existing hooks.
#
# The Codex CLI fires Claude-style lifecycle hooks from hooks.json, which gives Codex
# the same pod integration Claude Code gets: instant state dots on the pod strip, work-
# headline capture, startup pod-awareness, and pod-mail injected silently as context at
# its next prompt (no send-keys). The wiring:
#
#   SessionStart      -> pod-codex-state idle                   (back at the prompt)
#                        pod-awareness.sh codex                 (roster + stamp this window as codex)
#   UserPromptSubmit  -> pod-codex-state busy user_prompt_submit  (a turn started; also @work)
#                        pod-mail-check UserPromptSubmit        (surface unread pod-mail)
#   PermissionRequest -> pod-codex-state wait                   (a permission prompt is up)
#   PostToolUse       -> pod-codex-state busy                   (rescue a stuck wait dot)
#   Stop              -> pod-codex-state idle stop --json       (turn finished; Codex
#                                                                requires JSON on Stop stdout)
#
# If bin/pod-brief exists (an optional module), SessionStart/UserPromptSubmit also get
# its boot/refresh entries; if bin/pod-primer exists, SessionStart also injects the role
# primer + operator memory. Absent, they're simply not wired (re-run to add).
#
# Idempotent: a pod hook is added only if an identical command isn't already present,
# so re-running is safe. Existing non-pod hooks are left intact. hooks.json is backed
# up first and rewritten atomically (tempfile + os.replace). Entries carry no timeout
# field — mirroring the plain {type, command} shape Codex reads.
#
# Hook commands use ABSOLUTE resolved paths under this repo's bin ($POD_BIN), so the
# wiring survives a relocated repo as long as the files stay where install.sh found them.
# If the repo DID move, re-running heals rather than accumulates: pod hook entries that
# point at a different checkout are pruned before the new group is appended.
set -uo pipefail
POD_BIN="$(cd "$(dirname "$0")/../../bin" && pwd)"; . "$POD_BIN/_pod-paths.sh"

# the awareness hook is shared with the claude-code wiring; argv1 sets the stamped id.
# Built from the PHYSICAL repo root that _pod-paths.sh resolved, never from a logical
# `cd "$(dirname "$0")" && pwd`: every other command below comes from the symlink-resolved
# $POD_BIN, and a logical $0 keeps whatever symlinked component the caller typed (macOS
# /tmp -> /private/tmp, an autofs $HOME). The two spellings then disagree and uninstall.sh,
# which rebuilds this path from the physical $POD_BIN, could never match what we wrote.
AWARENESS="$POD_REPO/hooks/claude-code/pod-awareness.sh"

# optional modules: only wire these if they exist right now (a re-run picks them up).
BRIEF="$POD_BIN/pod-brief"
[ -x "$BRIEF" ] || BRIEF=""
PRIMER="$POD_BIN/pod-primer"
[ -x "$PRIMER" ] || PRIMER=""

# --- resolve target hooks.json -----------------------------------------------------
HOOKS_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hooks-file)
      [ "$#" -ge 2 ] || { echo "install.sh: --hooks-file requires a value" >&2; exit 2; }
      HOOKS_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "usage: install.sh [--hooks-file <path>]"
      echo "  Wires agent-pods Codex hooks into hooks.json."
      echo "  Default: \$CODEX_HOME/hooks.json else ~/.codex/hooks.json"
      exit 0 ;;
    *) echo "install.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$HOOKS_FILE" ]; then
  if [ -n "${CODEX_HOME:-}" ]; then
    HOOKS_FILE="$CODEX_HOME/hooks.json"
  else
    HOOKS_FILE="$HOME/.codex/hooks.json"
  fi
fi

command -v python3 >/dev/null 2>&1 || { echo "install.sh: python3 required" >&2; exit 1; }

# --- merge via python: back up, add only missing pod entries, atomic write ---------
python3 - "$HOOKS_FILE" "$POD_BIN" "$AWARENESS" "$BRIEF" "$PRIMER" <<'PY'
import json, os, shlex, shutil, sys, tempfile, datetime

hooks_path, pod_bin, awareness, brief, primer = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

# The pod hooks, per event. Each command is an absolute path under this repo's bin
# (or the shared awareness script). Order matters within an event group: state first,
# then context injectors.
WIRING = {
    "SessionStart": [
        'bash "%s/pod-codex-state" idle' % pod_bin,
        'bash "%s" codex' % awareness,
    ],
    "UserPromptSubmit": [
        'bash "%s/pod-codex-state" busy user_prompt_submit' % pod_bin,
        'bash "%s/pod-mail-check" UserPromptSubmit' % pod_bin,
    ],
    "PermissionRequest": [
        'bash "%s/pod-codex-state" wait' % pod_bin,
    ],
    "PostToolUse": [
        # rescue a stuck "wait" dot: a tool result mid-turn means the agent is working
        # again (e.g. a just-approved permission prompt). No-op when already busy.
        'bash "%s/pod-codex-state" busy' % pod_bin,
    ],
    "Stop": [
        'bash "%s/pod-codex-state" idle stop --json' % pod_bin,
    ],
}
if brief:
    WIRING["SessionStart"].append('bash "%s" boot' % brief)
    WIRING["UserPromptSubmit"].append('bash "%s" refresh UserPromptSubmit' % brief)
if primer:
    WIRING["SessionStart"].append('bash "%s"' % primer)

# --- load (tolerate missing / empty / malformed-but-recoverable) ---
data = {}
existed = os.path.exists(hooks_path)
if existed:
    try:
        with open(hooks_path) as f:
            txt = f.read().strip()
        data = json.loads(txt) if txt else {}
        if not isinstance(data, dict):
            print("install.sh: %s is not a JSON object; refusing to touch it" % hooks_path, file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print("install.sh: cannot parse %s (%s); refusing to touch it" % (hooks_path, e), file=sys.stderr)
        sys.exit(1)

hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print("install.sh: hooks.json 'hooks' is not an object; refusing to touch it", file=sys.stderr)
    sys.exit(1)

def existing_commands(event):
    """Set of every hook command string already wired for this event (any group)."""
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
# re-runs this installer would otherwise end up with BOTH sets wired: the dead one keeps
# firing `bash "/gone/bin/pod-codex-state" idle` on every event, and no uninstaller run
# from the new location can reach it, because ownership was matched by exact string.
# So match on the SCRIPT instead: argv[1]'s basename, required to sit under a `bin/` or
# `hooks/claude-code/` parent. Tight enough that an unrelated user command never matches,
# loose enough to recognize our own entries from any prior checkout.
POD_BIN_SCRIPTS = {
    "pod-codex-state", "pod-mail-check", "pod-brief", "pod-primer",
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
        print("install.sh: hooks.%s is not an array; refusing to touch it" % event, file=sys.stderr)
        sys.exit(1)
    # Append our missing entries as one new group, so we never reorder or mutate a
    # user's existing groups.
    groups.append({
        "hooks": [{"type": "command", "command": c} for c in missing]
    })
    added.extend(["%s: %s" % (event, c) for c in missing])

if not added and not pruned:
    print("install.sh: all agent-pods Codex hooks already present in %s — nothing to do." % hooks_path)
    sys.exit(0)

# --- back up the existing file ---
if existed:
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup = "%s.pod-bak.%s" % (hooks_path, stamp)
    try:
        shutil.copy2(hooks_path, backup)
        print("install.sh: backed up %s -> %s" % (hooks_path, backup))
    except Exception as e:
        print("install.sh: backup failed (%s); aborting" % e, file=sys.stderr)
        sys.exit(1)

# --- atomic write ---
# Write to the REALPATH, not the path we were handed: os.replace() acts on the link
# itself, so a dotfiles-managed hooks.json (stow/chezmoi/yadm point ~/.codex/hooks.json
# at a repo file) would be silently detached and replaced by a regular file — the dotfiles
# copy keeps being edited and never takes effect again. Resolving first also puts the
# tempfile on the real file's filesystem, which is what makes the rename atomic.
real_path = os.path.realpath(hooks_path)
os.makedirs(os.path.dirname(real_path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real_path), prefix=".hooks.", suffix=".tmp")
try:
    os.fchmod(fd, (os.stat(hooks_path).st_mode & 0o777) if existed else 0o600)
    with os.fdopen(fd, "w") as tf:
        json.dump(data, tf, indent=2)
        tf.write("\n")
    os.replace(tmp, real_path)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise

if pruned:
    print("install.sh: pruned %d pod hook(s) from a previous repo location in %s:" % (len(pruned), hooks_path))
    for p in pruned:
        print("  - " + p)
if added:
    print("install.sh: wired %d pod hook(s) into %s:" % (len(added), hooks_path))
    for a in added:
        print("  + " + a)
PY

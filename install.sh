#!/usr/bin/env bash
# install.sh — set up agent-pods on this machine. No sudo, no network, idempotent.
#
# What it does:
#   1. Preflight the hard dependencies (tmux >= 3.3, jq, python3 >= 3.11, bash >= 3.2)
#      and HARD FAIL with an actionable message if any is missing or too old.
#   2. Auto-detect which agents you actually have on PATH (via pod-adapter), and seed
#      ~/.config/pod/slots.json with the "+" quick-pick slots for them. If only the
#      generic shell is found, slot 0 is a plain shell — agent-pods still works.
#   3. Drop ~/.config/pod/config.sh from the example if you don't have one yet.
#   4. Symlink bin/* into ~/.local/bin so `pod-launch` etc. are on your PATH.
#   5. Optionally wire the agent lifecycle hooks (Claude Code and Codex, each only if
#      the agent is present).
#
# Re-running is safe: existing slots.json / config.sh are never clobbered (a replaced
# slots.json is backed up first), symlinks are refreshed in place, and the hook wiring
# is itself idempotent.
#
#   ./install.sh                    interactive
#   ./install.sh --with-claude-hooks   non-interactively wire the Claude Code hooks
#   ./install.sh --no-claude-hooks     non-interactively skip them
#   ./install.sh --with-codex-hooks    non-interactively wire the Codex hooks
#   ./install.sh --no-codex-hooks      non-interactively skip them
#   ./install.sh --no-logins           compatibility flag; bundled discovery needs no API key
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
POD_BIN="$REPO/bin"
ADAPTER="$POD_BIN/pod-adapter"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pod"
SLOTS="$CONFIG_DIR/slots.json"
CONFIG="$CONFIG_DIR/config.sh"
CONFIG_EXAMPLE="$REPO/config/config.sh.example"
LOCAL_BIN="$HOME/.local/bin"
CLAUDE_HOOKS_INSTALLER="$REPO/hooks/claude-code/install.sh"
CODEX_HOOKS_INSTALLER="$REPO/hooks/codex/install.sh"

# --with-* / --no-* let CI / scripts skip the interactive prompts.
HOOKS_CHOICE="ask"
CODEX_HOOKS_CHOICE="ask"
LOGINS_CHOICE="ask"
for arg in "$@"; do
  case "$arg" in
    --with-claude-hooks) HOOKS_CHOICE="yes" ;;
    --no-claude-hooks)   HOOKS_CHOICE="no" ;;
    --with-codex-hooks)  CODEX_HOOKS_CHOICE="yes" ;;
    --no-codex-hooks)    CODEX_HOOKS_CHOICE="no" ;;
    --with-logins)       LOGINS_CHOICE="yes" ;;
    --no-logins)         LOGINS_CHOICE="no" ;;
    -h|--help)
      echo "usage: install.sh [--with-claude-hooks|--no-claude-hooks] [--with-codex-hooks|--no-codex-hooks] [--with-logins|--no-logins]"
      echo "  Installs agent-pods: preflight deps, seed slots, symlink bin/* onto PATH."
      echo "  --with-logins   set up any custom API-backed adapters (bundled agents need no key)"
      exit 0 ;;
    *) echo "install.sh: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*" >&2; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# --- 1. preflight ----------------------------------------------------------------
# Each check HARD FAILS with a fix-it message. The +/⚙/☰/✕ status-line UX rides on
# tmux status-line mouse ranges, which need tmux 3.3; tomllib (the catalog reader)
# needs python 3.11; jq backs the worker registry; bash 3.2 is the macOS floor.
say "Preflight"

# tmux present + version. `tmux -V` prints like "tmux 3.6b" or "tmux 3.3a"; we take the
# leading "major.minor" and compare numerically (3.3 is the floor for status mouse ranges).
TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
[ -n "$TMUX_BIN" ] || die "tmux not found on PATH. Install it (macOS: brew install tmux; Debian/Ubuntu: apt install tmux) and re-run."
tmux_ver_raw="$("$TMUX_BIN" -V 2>/dev/null | awk '{print $2}')"
# strip any trailing letter suffix (3.6b -> 3.6) before splitting on the dot
tmux_ver_num="$(printf '%s' "$tmux_ver_raw" | tr -cd '0-9.')"
tmux_major="${tmux_ver_num%%.*}"
tmux_rest="${tmux_ver_num#*.}"
tmux_minor="${tmux_rest%%.*}"
case "$tmux_major" in ''|*[!0-9]*) tmux_major=0 ;; esac
case "$tmux_minor" in ''|*[!0-9]*) tmux_minor=0 ;; esac
if [ "$tmux_major" -lt 3 ] || { [ "$tmux_major" -eq 3 ] && [ "$tmux_minor" -lt 3 ]; }; then
  die "tmux $tmux_ver_raw is too old. agent-pods needs tmux >= 3.3 (the clickable status-line UX uses status-line mouse ranges, added in 3.3). Upgrade tmux and re-run."
fi
ok "tmux $tmux_ver_raw ($TMUX_BIN)"

# jq present
JQ_BIN="$(command -v jq 2>/dev/null || true)"
[ -n "$JQ_BIN" ] || die "jq not found on PATH. Install it (macOS: brew install jq; Debian/Ubuntu: apt install jq) and re-run."
ok "jq $("$JQ_BIN" --version 2>/dev/null) ($JQ_BIN)"

# python3 >= 3.11 (tomllib)
PY_BIN="$(command -v python3 2>/dev/null || true)"
[ -n "$PY_BIN" ] || die "python3 not found on PATH. Install Python 3.11+ and re-run."
if ! "$PY_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
  py_ver="$("$PY_BIN" -c 'import sys; print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?')"
  die "python3 is $py_ver but agent-pods needs >= 3.11 (the adapter catalog uses tomllib, added in 3.11). Upgrade python3 and re-run."
fi
ok "python3 $("$PY_BIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])') ($PY_BIN)"

# bash >= 3.2 (macOS default). We're running under bash; assert the floor.
bash_major="${BASH_VERSINFO[0]:-0}"
bash_minor="${BASH_VERSINFO[1]:-0}"
if [ "$bash_major" -lt 3 ] || { [ "$bash_major" -eq 3 ] && [ "$bash_minor" -lt 2 ]; }; then
  die "bash ${BASH_VERSION:-?} is too old; agent-pods needs bash >= 3.2. Run this installer with a newer bash."
fi
ok "bash ${BASH_VERSION:-?}"

# --- 2. detect agents + seed slots -----------------------------------------------
say ""
say "Detecting installed agents"
# pod-adapter list --available prints every adapter whose [launch].base_cmd resolves on
# PATH (generic-shell always qualifies — its base is a ${SHELL} expansion). One id/line.
AVAILABLE="$(POD_REPO="$REPO" "$PY_BIN" "$ADAPTER" list --available 2>/dev/null)"
if [ -z "$AVAILABLE" ]; then
  warn "pod-adapter reported no available agents (unexpected). Falling back to generic-shell."
  AVAILABLE="generic-shell"
fi
n_found=0
for aid in $AVAILABLE; do
  n_found=$((n_found + 1))
  ok "found: $aid"
done

mkdir -p "$CONFIG_DIR" 2>/dev/null || die "cannot create config dir $CONFIG_DIR"

# Build slots.json: up to 10 slots, one per FOUND agent at its default model/effort.
# NEVER clobber an existing slots.json — back it up if we replace it (we only replace
# when there is no file; otherwise we leave the user's curated slots alone entirely).
if [ -f "$SLOTS" ]; then
  ok "slots.json already exists — leaving it untouched ($SLOTS)"
else
  # Generate slots via python so we can validate each adapter and render its default
  # card. Agent slots store only semantic selections; the quick picker derives the
  # current command and label from local discovery when it opens/clicks.
  POD_REPO="$REPO" POD_BIN="$POD_BIN" "$PY_BIN" - "$ADAPTER" "$SLOTS" $AVAILABLE <<'PY'
import json, os, subprocess, sys

adapter, slots_path = sys.argv[1], sys.argv[2]
available = sys.argv[3:]

def adapter_call(*args):
    try:
        out = subprocess.run([sys.executable, adapter, *args],
                             capture_output=True, text=True)
        if out.returncode != 0:
            return ""
        return out.stdout.strip()
    except Exception:
        return ""

slots = []
for aid in available:
    if len(slots) >= 10:
        break
    if aid == "generic-shell":
        # a plain shell window: no model/effort, the floor that always works.
        label = adapter_call("card", aid) or "Shell"
        slots.append({"agent": aid, "model": "", "effort": "", "label": label})
        continue
    model = adapter_call("field", aid, "model")
    effort = adapter_call("field", aid, "effort")
    cmd = adapter_call("launch", aid, "--model", model, "--effort", effort)
    label = adapter_call("card", aid, "--model", model, "--effort", effort)
    if not cmd:
        continue
    slots.append({
        "agent": aid, "model": model, "effort": effort,
        "label": label or aid,
    })

# Ensure at least one usable slot even if everything above came up empty.
if not slots:
    slots.append({"agent": "generic-shell", "model": "", "effort": "",
                  "label": "Shell"})

data = {"title": "Spawn agent (0-9)", "slots": slots}
os.makedirs(os.path.dirname(slots_path), exist_ok=True)
tmp = slots_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, slots_path)
print("  ok    seeded %d slot(s) -> %s" % (len(slots), slots_path))
PY
  [ $? -eq 0 ] || die "failed to seed slots.json"
fi

# --- 3. config.sh from the example -----------------------------------------------
say ""
say "Runtime config"
if [ -f "$CONFIG" ]; then
  ok "config.sh already exists — leaving it untouched ($CONFIG)"
elif [ -f "$CONFIG_EXAMPLE" ]; then
  cp "$CONFIG_EXAMPLE" "$CONFIG" && ok "wrote $CONFIG from the example" \
    || warn "could not write $CONFIG (you can copy config/config.sh.example by hand)"
else
  warn "no config.sh.example in the repo; skipping (defaults apply)."
fi

# --- 4. symlink bin/* into ~/.local/bin ------------------------------------------
say ""
say "Linking commands into $LOCAL_BIN"
mkdir -p "$LOCAL_BIN" 2>/dev/null || die "cannot create $LOCAL_BIN"
linked=0
for f in "$POD_BIN"/*; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  # Link EVERYTHING, including the _pod-* helper libraries. Each pod-* script
  # bootstraps with `POD_BIN="$(cd "$(dirname "$0")" && pwd)"; . "$POD_BIN/_pod-paths.sh"`,
  # so it sources the helper as a sibling of $0, which under a symlinked install
  # is the link in $LOCAL_BIN. If the _pod-* helpers aren't linked here too, every
  # command dies at startup with `_pod-paths.sh: No such file or directory`.
  # The helpers carry their own symlink-following logic to resolve POD_REPO back to
  # the real tree, so linking them is correct and relocatable.
  # make the real file executable so the symlink is runnable — but NOT the _-prefixed
  # helper libraries: they're SOURCED (`. "$POD_BIN/_pod-paths.sh"`), never executed,
  # so they ship non-executable (644). chmod-ing them here rewrites the tracked mode
  # in a git checkout, which dirties the working tree and makes the next `git pull`
  # fail ("local changes would be overwritten"). Sourcing needs no +x, so skip them.
  case "$base" in
    _*) : ;;                                  # sourced helper: leave its mode alone
    *)  chmod +x "$f" 2>/dev/null || true ;;
  esac
  ln -sf "$f" "$LOCAL_BIN/$base"
  linked=$((linked + 1))
done
ok "linked $linked command(s)"

# PATH advisory — we never silently edit the user's shell rc.
case ":$PATH:" in
  *":$LOCAL_BIN:"*) ok "$LOCAL_BIN is already on your PATH" ;;
  *)
    warn "$LOCAL_BIN is NOT on your PATH. Add this line to your shell rc (~/.zshrc or ~/.bashrc):"
    printf '\n      export PATH="%s:$PATH"\n\n' "$LOCAL_BIN"
    ;;
esac

# --- 5. optional Claude Code hooks -----------------------------------------------
say ""
say "Claude Code lifecycle hooks"
have_claude=0
for aid in $AVAILABLE; do
  [ "$aid" = "claude-code" ] && have_claude=1
done
if [ "$have_claude" -ne 1 ]; then
  ok "Claude Code not detected — skipping hook wiring (nothing to do)."
elif [ ! -x "$CLAUDE_HOOKS_INSTALLER" ]; then
  warn "Claude Code present but $CLAUDE_HOOKS_INSTALLER is missing/not executable — skipping."
else
  do_hooks="no"
  case "$HOOKS_CHOICE" in
    yes) do_hooks="yes" ;;
    no)  do_hooks="no"; ok "skipping Claude Code hooks (--no-claude-hooks)" ;;
    ask)
      # default N: only proceed on an explicit yes. Non-interactive (no tty) -> skip.
      if [ -t 0 ]; then
        printf '  Claude Code is installed. Wire the agent-pods lifecycle hooks into your\n'
        printf '  Claude Code settings.json (instant state dots, pod-mail delivery)? [y/N] '
        read -r reply
        case "$reply" in [Yy]*) do_hooks="yes" ;; *) do_hooks="no" ;; esac
      else
        ok "non-interactive and no --with-claude-hooks flag — skipping (run hooks/claude-code/install.sh later, or re-run with --with-claude-hooks)."
      fi ;;
  esac
  if [ "$do_hooks" = "yes" ]; then
    if "$CLAUDE_HOOKS_INSTALLER"; then
      ok "Claude Code hooks wired"
    else
      warn "Claude Code hook installer exited non-zero — see its output above."
    fi
  fi
fi

# --- 5b. optional Codex hooks ------------------------------------------------------
# Codex fires the same Claude-style lifecycle hooks (from ~/.codex/hooks.json), so it
# gets the identical offer: instant state dots + pod-mail injected as context.
say ""
say "Codex lifecycle hooks"
have_codex=0
for aid in $AVAILABLE; do
  [ "$aid" = "codex" ] && have_codex=1
done
if [ "$have_codex" -ne 1 ]; then
  ok "Codex not detected — skipping hook wiring (nothing to do)."
elif [ ! -x "$CODEX_HOOKS_INSTALLER" ]; then
  warn "Codex present but $CODEX_HOOKS_INSTALLER is missing/not executable — skipping."
else
  do_codex_hooks="no"
  case "$CODEX_HOOKS_CHOICE" in
    yes) do_codex_hooks="yes" ;;
    no)  do_codex_hooks="no"; ok "skipping Codex hooks (--no-codex-hooks)" ;;
    ask)
      # default N: only proceed on an explicit yes. Non-interactive (no tty) -> skip.
      if [ -t 0 ]; then
        printf '  Codex is installed. Wire the agent-pods lifecycle hooks into your\n'
        printf '  ~/.codex/hooks.json (instant state dots, pod-mail delivery)? [y/N] '
        read -r reply
        case "$reply" in [Yy]*) do_codex_hooks="yes" ;; *) do_codex_hooks="no" ;; esac
      else
        ok "non-interactive and no --with-codex-hooks flag — skipping (run hooks/codex/install.sh later, or re-run with --with-codex-hooks)."
      fi ;;
  esac
  if [ "$do_codex_hooks" = "yes" ]; then
    if "$CODEX_HOOKS_INSTALLER"; then
      ok "Codex hooks wired"
    else
      warn "Codex hook installer exited non-zero — see its output above."
    fi
  fi
fi

# --- 6. optional: log in for custom API-backed discovery -------------------------
# Bundled agents discover from their local CLI/provider and never need an extra key.
# Preserve pod-login support only for a user-supplied adapter that explicitly declares
# [discover].auth.
say ""
say "Custom API-backed model discovery"
login_agents=""
for aid in $AVAILABLE; do
  prov="$("$ADAPTER" field "$aid" auth 2>/dev/null)"
  [ -n "$prov" ] || continue
  if "$POD_BIN/pod-discover-api" "$prov" >/dev/null 2>&1; then
    ok "$aid: already pulling live models from $prov"
  else
    login_agents="$login_agents $aid"
  fi
done
if [ -z "$login_agents" ]; then
  ok "nothing to set up here."
else
  do_login="no"
  case "$LOGINS_CHOICE" in
    yes) do_login="yes" ;;
    no)  ok "skipping custom API logins (--no-logins):$login_agents" ;;
    ask)
      if [ -t 0 ]; then
        printf '  These custom adapters declare API-key discovery:%s\n' "$login_agents"
        printf '  Set that up now? [y/N] '
        read -r reply
        case "$reply" in [Yy]*) do_login="yes" ;; *) do_login="no" ;; esac
      else
        ok "non-interactive — run 'pod-login' later to pull live models for:$login_agents"
      fi ;;
  esac
  if [ "$do_login" = "yes" ]; then
    for aid in $login_agents; do "$POD_BIN/pod-login" "$aid" || true; done
  fi
fi

# --- summary ---------------------------------------------------------------------
say ""
say "agent-pods installed."
say "  repo:    $REPO"
say "  config:  $CONFIG_DIR (slots.json, config.sh)"
say "  bin:     symlinked into $LOCAL_BIN"
say ""
case ":$PATH:" in
  *":$LOCAL_BIN:"*) say "Launch a pod with:  pod-launch" ;;
  *)               say "After adding $LOCAL_BIN to PATH, launch a pod with:  pod-launch" ;;
esac

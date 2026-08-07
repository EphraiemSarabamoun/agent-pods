#!/usr/bin/env bash
# install.sh — set up agent-pods on this machine. No sudo, no network, idempotent.
#
# What it does:
#   1. Preflight. HARD FAIL only on what has no fallback (tmux >= 3.0, python3,
#      bash >= 3.2); WARN — and continue — on the optional ones (jq, tmux < 3.3,
#      python3 < 3.11), naming exactly which feature degrades.
#   2. Auto-detect which agents you actually have on PATH (via pod-adapter), and seed
#      ~/.config/pod/slots.json with the "+" quick-pick slots for them. If only the
#      generic shell is found, slot 0 is a plain shell — agent-pods still works.
#   3. Drop ~/.config/pod/config.sh from the example if you don't have one yet.
#   4. Symlink bin/* into ~/.local/bin so `pod-launch` etc. are on your PATH, and
#      shim the optional modules' commands (modules/queue's mgr-*) alongside them.
#   5. Optionally wire the agent lifecycle hooks (Claude Code and Codex, each only if
#      the agent is present).
#
# Re-running is safe: existing slots.json / config.sh are never clobbered (a replaced
# slots.json is backed up first), symlinks are refreshed in place, and the hook wiring
# is itself idempotent. A pre-existing ~/.local/bin entry that is NOT ours is moved to
# <name>.pre-agent-pods rather than overwritten (uninstall.sh puts it back).
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
# TWO TIERS, deliberately. HARD FAIL only where the deck has no fallback at all
# (tmux itself, python3, bash 3.2). Everything else WARNS and continues, naming the
# exact feature that degrades — because the dominant enterprise baseline (Ubuntu
# 22.04 LTS: tmux 3.2a, python 3.10, frequently no jq and no sudo to add one) runs
# the deck fine minus a couple of affordances. Refusing to install there bought
# nothing: the user could not have satisfied the gate anyway.
say "Preflight"

# tmux present + version. `tmux -V` prints like "tmux 3.6b" or "tmux 3.3a"; we take the
# leading "major.minor" and compare numerically. 3.0 is the hard floor (display-menu,
# which every picker is built on); 3.3 is where the clickable status line starts.
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
if [ "$tmux_major" -lt 3 ]; then
  die "tmux $tmux_ver_raw is too old. agent-pods needs tmux >= 3.0 — the + / ⚙ / ☰ pickers are display-menu, added in 3.0, and there is no fallback for them. Upgrade tmux and re-run."
fi
ok "tmux $tmux_ver_raw ($TMUX_BIN)"
if [ "$tmux_major" -eq 3 ] && [ "$tmux_minor" -lt 3 ]; then
  warn "tmux $tmux_ver_raw predates 3.3, so the CLICKABLE status line is off: + / ⚙ / ☰ / ✕ and the ⚡ AUTO pill won't respond to the mouse (they ride #{mouse_status_range}, new in 3.3). Every one of them has a keyboard chord that pod-launch binds anyway (C-a n, C-a s, C-a a, ...), so the deck is fully usable — this is a UX downgrade, not a blocker. Note that only 3.3+ is exercised by our test suite."
  if [ "$tmux_minor" -lt 2 ]; then
    warn "tmux $tmux_ver_raw is also below 3.2: display-popup is missing, so the ⭐ standings board and the FULL AUTO flip animation will silently do nothing."
  fi
fi

# jq is OPTIONAL — advisory only, matching pod-doctor. The core deck routes every JSON
# read through pod_json_get's jq -> python3 -> raw-stdout chain (bin/_pod-paths.sh), and
# the handful of bin/ scripts that shell out to jq directly all degrade gracefully. Only
# the OPTIONAL queue module (modules/queue) hard-depends on it, so a missing jq must not
# stop an install on a locked-down box that will never use the queue.
JQ_BIN="$(command -v jq 2>/dev/null || true)"
if [ -n "$JQ_BIN" ]; then
  ok "jq $("$JQ_BIN" --version 2>/dev/null) ($JQ_BIN)"
else
  warn "jq not found — that is fine for the core deck (JSON falls back to python3), but the OPTIONAL queue module (mgr-stage / mgr-queue / mgr-dispatch / mgr-poll / mgr-pick-next / mgr-status) needs it, and those commands drive FULL AUTO. Add it later with 'brew install jq' (macOS), 'apt install jq' (Debian/Ubuntu), or by dropping the static jq binary into ~/.local/bin (no sudo needed)."
fi

# python3 is required outright (JSON I/O, the spawn/settings menus, pod-workers-json).
# The >= 3.11 part is NOT: it is scoped to bin/pod-adapter, which parses adapters/*.toml
# with tomllib. Below 3.11 that one reader exits 3 and install.sh's agent detection falls
# through to generic-shell, which is a real but survivable degradation — so warn, and say
# precisely what is lost plus a remedy that needs no root.
PY_BIN="$(command -v python3 2>/dev/null || true)"
[ -n "$PY_BIN" ] || die "python3 not found on PATH. agent-pods uses it for every JSON read/write and for the spawn menus; install Python 3 (3.11+ preferred) and re-run."
py_ver="$("$PY_BIN" -c 'import sys; print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo '?')"
ok "python3 $py_ver ($PY_BIN)"
if ! "$PY_BIN" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null; then
  warn "python3 $py_ver is below 3.11, so pod-adapter cannot read the adapter catalog (adapters/*.toml is parsed with tomllib, new in 3.11). What that costs: agent auto-detection, the per-agent model/effort quick-pick slots, and the agent list in the + / ⚙ menus — new windows open as a plain shell, from which you can still start any agent by typing its own command. Everything else (pod-launch, the roster, pod-tell/pod-mail, state dots, gold stars) is unaffected. Sudo-free fix: put a newer python3 first on PATH — 'uv python install 3.12', 'pyenv install 3.12', or a micromamba/conda env — then re-run this installer."
fi

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
link_failed=0
moved_aside=0

# Did WE write this file (as a module shim, below)? Shims carry a marker line so a
# re-run refreshes its own shim in place instead of mistaking it for a stranger's
# script and backing it up on every run.
is_our_shim() {
  [ -f "$1" ] || return 1
  head -n 8 "$1" 2>/dev/null | grep -q '^# agent-pods-shim:'
}

# Make $LOCAL_BIN/<name> safe to write, or refuse. `ln -sf` UNLINKS the destination
# first, so without this an unrelated ~/.local/bin/pod (a podman or kubectl helper —
# several of our names are that generic) is silently destroyed, and uninstall.sh
# removes our link without putting anything back. Policy: anything that is not already
# ours moves aside to <name>.pre-agent-pods, which uninstall.sh restores; if that
# backup slot is already occupied we touch neither and skip the command. Returns 1
# when the caller must skip.
clear_dest() {
  cd_dest="$1"; cd_base="$(basename "$cd_dest")"
  if [ -L "$cd_dest" ]; then
    cd_tgt="$(readlink "$cd_dest" 2>/dev/null || true)"
    # resolve a relative target against the link's own directory before comparing
    case "$cd_tgt" in
      /*) cd_res="$cd_tgt" ;;
      *)  cd_res="$LOCAL_BIN/$cd_tgt" ;;
    esac
    case "$cd_res" in
      "$REPO"/*) return 0 ;;      # our own link from a previous run: refresh in place
    esac
  elif [ ! -e "$cd_dest" ]; then
    return 0                      # nothing in the way (also covers a dangling non-link)
  elif is_our_shim "$cd_dest"; then
    return 0                      # our own shim from a previous run: rewrite in place
  fi
  cd_bak="$cd_dest.pre-agent-pods"
  if [ -e "$cd_bak" ] || [ -L "$cd_bak" ]; then
    warn "$cd_base exists in $LOCAL_BIN and is not ours, and $cd_base.pre-agent-pods is already taken — leaving both alone, NOT installing $cd_base"
    return 1
  fi
  if ! mv "$cd_dest" "$cd_bak" 2>/dev/null; then
    warn "$cd_base exists in $LOCAL_BIN and is not ours, and could not be moved aside — leaving it alone, NOT installing $cd_base"
    return 1
  fi
  moved_aside=$((moved_aside + 1))
  warn "$cd_base already existed in $LOCAL_BIN and was not ours — backed it up as $cd_base.pre-agent-pods (uninstall.sh restores it)"
  return 0
}

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
  clear_dest "$LOCAL_BIN/$base" || { link_failed=$((link_failed + 1)); continue; }
  # Check ln's exit status: when $LOCAL_BIN exists but is not writable (MDM-provisioned
  # mode 555, a read-only overlay), mkdir -p above succeeds and EVERY ln fails. Counting
  # unconditionally used to report "linked 50 command(s)" and exit 0 on an empty dir.
  if ln -sf "$f" "$LOCAL_BIN/$base" 2>/dev/null; then
    linked=$((linked + 1))
  else
    link_failed=$((link_failed + 1))
    warn "could not link $base into $LOCAL_BIN"
  fi
done
# Nothing linked means nothing was installed — the _pod-* helpers are missing too, so
# every command would die at startup. Fail loudly instead of printing a success banner.
if [ "$linked" -eq 0 ]; then
  die "linked 0 of $link_failed command(s) into $LOCAL_BIN — nothing was installed. Is $LOCAL_BIN writable? Fix its permissions (or point HOME elsewhere) and re-run."
fi
ok "linked $linked command(s)"
[ "$moved_aside" -eq 0 ] || ok "moved $moved_aside pre-existing file(s) aside as *.pre-agent-pods"

# --- 4b. shim the optional modules' commands onto PATH ----------------------------
# lib/primer/manager.md (injected at every manager SessionStart) and pod-auto-brief
# (injected on every prompt while FULL AUTO is on) both tell the agent to run
# mgr-stage / mgr-queue / mgr-pick-next by BARE NAME, so they have to resolve on PATH
# or the whole autonomy substrate dead-ends at `command not found`.
#
# They cannot be symlinked the way bin/* is. Each mgr-* bootstraps with
# `POD_BIN="$(cd "$(dirname "$0")/../../../bin" && pwd)"` and, unlike bin/_pod-paths.sh,
# does NOT walk the symlink chain first — so from a link in ~/.local/bin that hop
# resolves to ~/../../bin and the script dies on `_pod-paths.sh: No such file or
# directory`. A one-line exec shim keeps $0 pointing at the real file inside the
# module, so the module's own resolution (and its $QBIN sibling lookup) works
# untouched, and stays correct if the module's layout ever changes.
say ""
say "Linking optional module commands into $LOCAL_BIN"
mod_linked=0
mod_seen=0
for f in "$REPO"/modules/*/bin/*; do
  [ -f "$f" ] || continue                     # unmatched glob stays literal under set -u
  base="$(basename "$f")"
  case "$base" in _*) continue ;; esac        # sourced helper, not a command
  mod_seen=$((mod_seen + 1))
  chmod +x "$f" 2>/dev/null || true
  clear_dest "$LOCAL_BIN/$base" || { link_failed=$((link_failed + 1)); continue; }
  # rm first: whatever survived clear_dest is a symlink into THIS repo (ours from an
  # older install, or one the user made by hand following modules/queue/README), and
  # `>` follows a symlink — it would overwrite the real module file in the repo.
  rm -f "$LOCAL_BIN/$base" 2>/dev/null || true
  if printf '#!/usr/bin/env bash\n# agent-pods-shim: %s\n# Written by install.sh. An exec shim, not a symlink, so $0 stays inside the module\n# and its own `dirname $0/../../../bin` bootstrap still finds bin/_pod-paths.sh.\nexec "%s" "$@"\n' "$f" "$f" > "$LOCAL_BIN/$base" 2>/dev/null &&
     chmod +x "$LOCAL_BIN/$base" 2>/dev/null; then
    mod_linked=$((mod_linked + 1))
  else
    link_failed=$((link_failed + 1))
    warn "could not install the $base shim into $LOCAL_BIN"
  fi
done
if [ "$mod_seen" -eq 0 ]; then
  ok "no optional module commands found — nothing to link."
elif [ "$mod_linked" -eq 0 ]; then
  warn "none of the $mod_seen optional module command(s) could be installed — FULL AUTO will not work until they are on PATH."
else
  ok "shimmed $mod_linked module command(s) onto PATH (queue: mgr-*)"
  [ -n "$JQ_BIN" ] || warn "those queue commands require jq, which is missing (see Preflight) — install jq before using FULL AUTO."
fi

# --- 4c. a launcher named after YOUR manager --------------------------------------
# If you named the manager seat (POD_MANAGER_NAME in config.sh), install a command by
# that name that opens/attaches a pod — so `hermes` is a synonym for `pod-launch` and
# the deck answers to whatever you call it. Nothing persona-specific ships in the repo:
# the name comes from your local config at install time.
#
# Strictly opt-in and strictly non-destructive. We claim a name on PATH only when it is
# genuinely free; anything already answering to it (a real binary, another launcher of
# your own) wins and we skip with a warning. A name you picked is trivial to change,
# so the move-aside policy used for our fixed command names would be the wrong trade.
alias_installed=""
mgr_name="$( [ -f "$CONFIG" ] && . "$CONFIG" >/dev/null 2>&1; printf '%s' "${POD_MANAGER_NAME:-}" )"
if [ -n "$mgr_name" ] && [ "$mgr_name" != "manager" ]; then
  say ""
  say "Manager-name launcher"
  alias_skip=""
  # a command name, not a display string: no spaces, slashes, dots or leading dash
  case "$mgr_name" in
    -*|.*)             alias_skip="'$mgr_name' starts with '-' or '.'" ;;
    *[!A-Za-z0-9_-]*)  alias_skip="'$mgr_name' has characters that cannot be a command name" ;;
  esac
  # never collide with one of our own fixed command names
  if [ -z "$alias_skip" ] && { [ -e "$POD_BIN/$mgr_name" ] || [ -e "$REPO/modules/$mgr_name" ]; }; then
    alias_skip="'$mgr_name' is already an agent-pods command"
  fi
  # never shadow anything that already answers to this name anywhere on PATH
  if [ -z "$alias_skip" ]; then
    existing="$(command -v "$mgr_name" 2>/dev/null || true)"
    if [ -n "$existing" ] && ! is_our_shim "$existing"; then
      alias_skip="'$mgr_name' is already a command on your PATH ($existing)"
    fi
  fi
  if [ -n "$alias_skip" ]; then
    warn "not installing a '$mgr_name' launcher — $alias_skip. Use pod-launch (or rename POD_MANAGER_NAME)."
  elif ! clear_dest "$LOCAL_BIN/$mgr_name"; then
    :   # clear_dest already explained itself
  else
    rm -f "$LOCAL_BIN/$mgr_name" 2>/dev/null || true
    if printf '#!/usr/bin/env bash\n# agent-pods-shim: %s\n# Written by install.sh from POD_MANAGER_NAME. A synonym for pod-launch.\nexec "%s" "$@"\n' \
         "$POD_BIN/pod-launch" "$POD_BIN/pod-launch" > "$LOCAL_BIN/$mgr_name" 2>/dev/null &&
       chmod +x "$LOCAL_BIN/$mgr_name" 2>/dev/null; then
      alias_installed="$mgr_name"
      ok "\`$mgr_name\` now opens a pod (same as pod-launch; \`$mgr_name <name>\` targets one)"
    else
      warn "could not install the '$mgr_name' launcher into $LOCAL_BIN"
    fi
  fi
fi

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
if [ "$link_failed" -eq 0 ]; then
  say "agent-pods installed."
else
  say "agent-pods installed WITH PROBLEMS."
fi
say "  repo:    $REPO"
say "  config:  $CONFIG_DIR (slots.json, config.sh)"
say "  bin:     $linked command(s) symlinked into $LOCAL_BIN"
[ "$mod_linked" -eq 0 ] || say "  modules: $mod_linked command(s) shimmed into $LOCAL_BIN"
[ "$moved_aside" -eq 0 ] || say "  saved:   $moved_aside pre-existing command(s) as *.pre-agent-pods"
say ""
case ":$PATH:" in
  *":$LOCAL_BIN:"*) say "Launch a pod with:  pod-launch" ;;
  *)               say "After adding $LOCAL_BIN to PATH, launch a pod with:  pod-launch" ;;
esac
# Exit non-zero on a partial install: a deck missing even one command is broken, and a
# wrapper script reading only our status must not record that as a success.
if [ "$link_failed" -gt 0 ]; then
  say ""
  warn "$link_failed command(s) could NOT be installed into $LOCAL_BIN (see the warnings above). This install is INCOMPLETE."
  exit 1
fi

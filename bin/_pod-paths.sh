#!/usr/bin/env bash
# _pod-paths.sh — the one place agent-pods resolves where it lives and what it's
# configured to do. SOURCE it; do not exec. Every pod-* script begins with:
#
#     POD_BIN="$(cd "$(dirname "$0")" && pwd)"; . "$POD_BIN/_pod-paths.sh"
#
# and then uses the exported POD_* vars below instead of any hardcoded path. This is
# what makes the repo relocatable: clone it anywhere, symlink bin/* onto PATH, and
# every script still finds its siblings, its adapters, and its state.
#
# Resolution survives a symlinked install (install.sh symlinks bin/* into ~/.local/bin):
# we follow the symlink chain of THIS file back to the real bin/ in the repo, so
# POD_BIN/POD_REPO always point at the real tree even when invoked via a link.
#
# Idempotent (guarded), safe under `set -u`, bash 3.2 safe (macOS ships bash 3.2).

[ -n "${__POD_PATHS_LOADED:-}" ] && return 0
__POD_PATHS_LOADED=1

# --- resolve the REAL path of this file, following symlinks ---------------------
__pp="${BASH_SOURCE[0]:-$0}"
while [ -h "$__pp" ]; do
  __d="$(cd -P "$(dirname "$__pp")" 2>/dev/null && pwd)"
  __pp="$(readlink "$__pp")"
  case "$__pp" in /*) ;; *) __pp="$__d/$__pp" ;; esac
done
POD_BIN="$(cd -P "$(dirname "$__pp")" 2>/dev/null && pwd)"
POD_REPO="$(cd -P "$POD_BIN/.." 2>/dev/null && pwd)"
unset __pp __d

# --- defaults (overridable by config + environment) -----------------------------
# uid, resolved ONCE. It scopes the runtime root AND backs the ownership check below,
# so "cannot resolve" must never be mistaken for a value: absolute path first (a
# minimal or hostile PATH can't redirect it), then PATH (NixOS/Termux ship no
# /usr/bin/id), then bash's own $EUID, which needs no binary at all.
__pod_uid="$(/usr/bin/id -u 2>/dev/null || id -u 2>/dev/null || printf '%s' "${EUID:-${UID:-}}")"

# tmux binary. Empty config -> resolve on PATH (no platform-specific hardcode).
# A CALLER-PINNED POD_TMUX opts out of the dedicated-socket shim below (that is how
# the test harnesses aim every "$T" call at an isolated server), so record the fact
# that it was pinned rather than inferring it from the value later: a pinned path can
# legitimately be identical to the one on PATH, and wrapping that in `-L` would hand
# the caller a different server than the one they asked for. $__pod_tmux_bin is the
# auto-resolved binary, kept because the shim must exec THAT, never itself.
case "${POD_TMUX:-}" in "") __pod_tmux_pinned=0 ;; *) __pod_tmux_pinned=1 ;; esac
__pod_tmux_bin="$(command -v tmux 2>/dev/null || echo tmux)"
POD_TMUX="${POD_TMUX:-$__pod_tmux_bin}"

# tmp roots: one tree, three subdirs.
#   state/  workers.json, tmux_group.json, log.jsonl, dispatched/<pod>/,
#           completed/<pod>/, *.pid, *.log
#   inbox/  <task-id>/{prompt.txt,result.json,DONE}, _queue/<pod>/, _templates/
#   comms/  <pod>/{channel.log, <wid>.mbox, <wid>.read, work/}            (pod-comms)
#
# The root is deliberately NOT derived from $TMPDIR. TMPDIR is per-CONTEXT: on macOS a
# GUI terminal gets /var/folders/<hash>/T/ while ssh/cron/launchd get none (-> /tmp),
# and a command sandbox can hand every single command its own scratch TMPDIR. A
# TMPDIR-derived root therefore forks one pod into two disjoint state trees — pod-tell
# reports delivery into a mailbox the recipient never reads and the registry looks empty
# from the other context — while the tmux deck keeps rendering as if all were well,
# because the SOCKET path never moved with it.
# A fixed /tmp path is the same choice tmux itself makes for its sockets
# (/tmp/tmux-<uid>): identical in every context, on local disk (flock is reliable,
# unlike a $HOME on NFS), and cleared on reboot — the exact lifetime this state wants.
# Privacy does not come from the location but from 0700 + the ownership and symlink
# checks below, again exactly as for /tmp/tmux-<uid>.
if [ -n "$__pod_uid" ]; then
  __pod_tmp_default="/tmp/agent-pods-$__pod_uid"
elif [ -n "${HOME:-}" ]; then
  # No uid from anywhere: an unscoped /tmp/agent-pods- would be a path SHARED by every
  # user on the host (and the ownership check would then reject whoever arrived
  # second). Scope to $HOME instead — private by construction.
  __pod_tmp_default="$HOME/.agent-pods"
else
  __pod_tmp_default=""
fi
POD_TMP="${POD_TMP:-$__pod_tmp_default}"
unset __pod_tmp_default

# deck identity (agent-agnostic: the manager defaults to a plain shell, not any one agent).
POD_SESSION_PREFIX="${POD_SESSION_PREFIX:-pod}"
# city-name pool for NEW pods (pod-city). Empty -> pod-city's built-in list. A
# space-separated list of single-word names overrides it; exhaustion falls back to
# the numeric <prefix>-N series.
POD_CITIES="${POD_CITIES:-}"
POD_MANAGER_NAME="${POD_MANAGER_NAME:-manager}"
# When FULL AUTO is on, pod-auto renames the manager window to this (to signal the
# mode). Defaults to POD_MANAGER_NAME, so the rename is a visible no-op unless you
# set a distinct name (e.g. "manager" normally, "autopilot" while FULL AUTO is on).
POD_MANAGER_NAME_AUTO="${POD_MANAGER_NAME_AUTO:-$POD_MANAGER_NAME}"
POD_MANAGER_CARD="${POD_MANAGER_CARD:-Shell · manager}"
# who gold stars are attributed to (stars are HUMAN-only). Shown in the award log +
# the delivered prompt. Defaults to "the human"; set to your name if you like.
POD_STAR_AWARDER="${POD_STAR_AWARDER:-the human}"
POD_MANAGER_CMD="${POD_MANAGER_CMD:-}"          # empty -> auto-pick (below), else shell
# When POD_MANAGER_CMD is unset, the manager seat defaults to the best agent actually
# installed, in this preference order; if none are present it falls back to the shell.
POD_MANAGER_PREFER="${POD_MANAGER_PREFER:-claude-code codex cursor openclaw}"

# foreign-state poller tuning
POD_FOREIGN_INTERVAL="${POD_FOREIGN_INTERVAL:-3}"
POD_FOREIGN_TRIM="${POD_FOREIGN_TRIM:-8}"

# --- user config: a plain sourced shell file (zero parse cost on the hook hot path).
# The agent CATALOG is rich TOML (adapters/*.toml); the runtime config is deliberately
# a flat shell file so pod-state (which fires on every turn) pays no python startup.
POD_CONFIG_DIR="${POD_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pod}"
POD_CONFIG="${POD_CONFIG:-$POD_CONFIG_DIR/config.sh}"
if [ -f "$POD_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$POD_CONFIG"
fi

# --- derived paths (after config, so config can move POD_TMP / POD_CONFIG_DIR) ----
POD_STATE="${POD_STATE:-$POD_TMP/state}"
POD_INBOX="${POD_INBOX:-$POD_TMP/inbox}"
POD_COMMS="${POD_COMMS:-$POD_TMP/comms}"

# Runtime state contains prompts, results, mail and pane metadata. Keep the default
# user-scoped and private, and reject a pre-planted symlink before creating anything.
# Explicit POD_TMP overrides remain supported but receive the same ownership/mode
# checks because recursive cleanup assumes this is an application-owned root.
if [ -z "$POD_TMP" ] || [ "$POD_TMP" = "/" ] || { [ -n "${HOME:-}" ] && [ "$POD_TMP" = "$HOME" ]; }; then
  printf 'pod: refusing broad runtime root: %s\n' "$POD_TMP" >&2
  return 1 2>/dev/null || exit 1
fi
if [ -L "$POD_TMP" ]; then
  printf 'pod: refusing symlink runtime root: %s\n' "$POD_TMP" >&2
  return 1 2>/dev/null || exit 1
fi
# Absolute path first (a minimal or hostile PATH can't redirect it), then PATH: on
# NixOS /bin holds only sh and on Termux neither /bin nor /usr/bin exists, and a hard
# failure here takes out EVERY pod command plus the hooks that source this file.
/bin/mkdir -p "$POD_TMP" "$POD_STATE" "$POD_INBOX" "$POD_COMMS" 2>/dev/null || \
mkdir -p "$POD_TMP" "$POD_STATE" "$POD_INBOX" "$POD_COMMS" 2>/dev/null || {
  printf 'pod: cannot create runtime root: %s\n' "$POD_TMP" >&2
  return 1 2>/dev/null || exit 1
}
# Resolve every created directory physically, then require the three application
# trees to remain strict descendants of POD_TMP. This keeps cleanup commands safe
# even when a config accidentally supplies `..` or a symlinked subdirectory.
__pod_tmp_real="$(cd -P "$POD_TMP" 2>/dev/null && pwd)"
__pod_state_real="$(cd -P "$POD_STATE" 2>/dev/null && pwd)"
__pod_inbox_real="$(cd -P "$POD_INBOX" 2>/dev/null && pwd)"
__pod_comms_real="$(cd -P "$POD_COMMS" 2>/dev/null && pwd)"
for __pod_child in "$__pod_state_real" "$__pod_inbox_real" "$__pod_comms_real"; do
  case "$__pod_child" in
    "$__pod_tmp_real"/*) ;;
    *)
      printf 'pod: runtime directories must live below %s (got %s)\n' "$__pod_tmp_real" "$__pod_child" >&2
      unset __pod_tmp_real __pod_state_real __pod_inbox_real __pod_comms_real __pod_child
      return 1 2>/dev/null || exit 1 ;;
  esac
done
POD_TMP="$__pod_tmp_real"
POD_STATE="$__pod_state_real"
POD_INBOX="$__pod_inbox_real"
POD_COMMS="$__pod_comms_real"
unset __pod_tmp_real __pod_state_real __pod_inbox_real __pod_comms_real __pod_child
case "$(/usr/bin/uname -s 2>/dev/null || uname -s 2>/dev/null)" in
  Darwin) __pod_owner="$(/usr/bin/stat -f '%u' "$POD_TMP" 2>/dev/null || stat -f '%u' "$POD_TMP" 2>/dev/null || true)" ;;
  *)      __pod_owner="$(/usr/bin/stat -c '%u' "$POD_TMP" 2>/dev/null || stat -c '%u' "$POD_TMP" 2>/dev/null || true)" ;;
esac
# An unreadable owner or an unresolvable uid means CANNOT VERIFY, never MISMATCH. An
# empty $(id -u) used to compare unequal to a root this user genuinely owns, aborting
# every pod command — and since the hooks source this file with `|| exit 0`, the whole
# awareness/comms tier went silently blind while the deck kept rendering. Only a
# KNOWN-different owner aborts.
if [ -n "$__pod_owner" ] && [ -n "$__pod_uid" ] && [ "$__pod_owner" != "$__pod_uid" ]; then
  printf 'pod: runtime root is owned by uid %s, not %s: %s\n' "$__pod_owner" "$__pod_uid" "$POD_TMP" >&2
  unset __pod_owner
  return 1 2>/dev/null || exit 1
fi
/bin/chmod 700 "$POD_TMP" "$POD_STATE" "$POD_INBOX" "$POD_COMMS" 2>/dev/null || \
  chmod 700 "$POD_TMP" "$POD_STATE" "$POD_INBOX" "$POD_COMMS" 2>/dev/null || true
unset __pod_owner __pod_uid

# --- dedicated tmux server (default) ------------------------------------------------
# pod-launch configures a deck with SERVER-GLOBAL tmux state: the window-status
# formats, renumber-windows, the window-renamed / session-closed hooks, and a table of
# root-key bindings. tmux has no per-session key table and no per-session default for
# window options, so on a SHARED server all of that lands on the sessions someone was
# already using for unrelated work — up to and including rebinding bare C-b, which IS
# the default prefix. agent-pods therefore runs on its OWN tmux server by default: same
# binary, different socket, and `tmux ls` on the user's server never changes. Set
# POD_TMUX_SOCKET= (empty) to opt back into the default server; set it to another name
# to keep separate decks apart.
#
# The socket is selected with `tmux -L <name>`, but POD_TMUX must stay ONE WORD: every
# consumer runs it as "$POD_TMUX" (pod-primer even tests it with -x, pod-settings-menu
# and pod-spawn-menu-build exec it from python, and pod-launch records it in
# tmux_group.json as `tmux_bin`, which is how the MCP inherits the socket with no env
# at all). So POD_TMUX points at a one-line exec shim — the same trick
# test/parity-sandbox.sh already uses — instead of word-splitting POD_TMUX at ~30 call
# sites. Living under POD_TMP means the shim's lifetime matches the state it serves.
POD_TMUX_SOCKET="${POD_TMUX_SOCKET-agent-pods}"
POD_TMUX_DEDICATED=0
if [ -n "$POD_TMUX_SOCKET" ]; then
  __pod_sock="$(LC_ALL=C printf '%s' "$POD_TMUX_SOCKET" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
  __pod_shim="$POD_TMP/tmux-$__pod_sock"
  # A seat that is ALREADY inside a pod pane talks to the server it actually lives on,
  # never to a socket named by config: plain tmux honors $TMUX, so leaving POD_TMUX
  # alone here is what keeps a pod launched on another server (one started before this
  # default existed, or a deliberate POD_TMUX_SOCKET= deck) fully working from inside
  # its own panes instead of silently losing its socket mid-flight. A pane in a NON-pod
  # tmux carries no POD_SESSION, so `pod-launch` typed in the user's own tmux still gets
  # the dedicated server rather than dropping a deck into their session list.
  __pod_seat=0
  if [ -n "${TMUX:-}" ] && [ -n "${POD_SESSION:-}" ]; then __pod_seat=1; fi
  # Honor a POD_TMUX pinned by the caller (env) or by config.sh (which can only have
  # moved it off the auto-resolved binary): only an untouched default gets the shim.
  # The last arm is the normal pane case — every seat of a dedicated-socket pod
  # inherits POD_TMUX=<shim> from the pod's own tmux environment, and that must still
  # count as "ours" so a shim someone deleted gets rebuilt instead of skipped.
  if { [ "$__pod_tmux_pinned" = 0 ] && [ "$__pod_seat" = 0 ] && [ "$POD_TMUX" = "$__pod_tmux_bin" ]; } \
     || [ "$POD_TMUX" = "$__pod_shim" ]; then
    if [ ! -x "$__pod_shim" ]; then
      # write-then-rename: a concurrent seat must never exec a half-written shim.
      __pod_new="$__pod_shim.$$"
      if printf "#!/bin/sh\nexec '%s' -L %s \"\$@\"\n" "$__pod_tmux_bin" "$__pod_sock" >"$__pod_new" 2>/dev/null; then
        /bin/chmod 700 "$__pod_new" 2>/dev/null || chmod 700 "$__pod_new" 2>/dev/null || true
        # Verify ONCE, at creation: a 0700 file on a noexec mount passes -x and still
        # fails to run, and a POD_TMUX that cannot exec takes the whole deck down.
        if "$__pod_new" -V >/dev/null 2>&1; then
          mv -f "$__pod_new" "$__pod_shim" 2>/dev/null || rm -f "$__pod_new" 2>/dev/null || true
        else
          rm -f "$__pod_new" 2>/dev/null || true
        fi
      else
        rm -f "$__pod_new" 2>/dev/null || true
      fi
      unset __pod_new
    fi
    # An unwritable or noexec runtime root falls back to the shared server rather than
    # to a dead command: degraded isolation beats a deck that cannot call tmux at all.
    if [ -x "$__pod_shim" ]; then POD_TMUX="$__pod_shim"; POD_TMUX_DEDICATED=1; fi
  fi
  unset __pod_sock __pod_shim __pod_seat
fi
unset __pod_tmux_bin __pod_tmux_pinned

# adapters: repo defaults, then user overrides (~/.config/pod/adapters/*.toml win by
# basename — handled by pod-adapter, which globs both with user last).
POD_ADAPTERS_DIR="${POD_ADAPTERS_DIR:-$POD_REPO/adapters}"
POD_USER_ADAPTERS="${POD_USER_ADAPTERS:-$POD_CONFIG_DIR/adapters}"
# the 10 quick-pick "+" slots: JSON (install-generated + edited via the gear menu, not
# hand-authored prose — so JSON, not TOML). The agent CATALOG is the rich TOML.
POD_SLOTS="${POD_SLOTS:-$POD_CONFIG_DIR/slots.json}"
POD_MODULES="${POD_MODULES:-$POD_REPO/modules}"

# operator memory: a user-local, appendable "how I run this pod" file (pod-remember
# writes it, pod-primer injects it at session start). Ships nothing — created on first
# `pod-remember`. Separate from the pod journal (ephemeral, per-pod) — this is durable
# and cross-session. The generic role primers pod-primer injects live in the repo.
POD_OPERATOR_MEMORY="${POD_OPERATOR_MEMORY:-$POD_CONFIG_DIR/operator-memory.md}"
POD_PRIMER_DIR="${POD_PRIMER_DIR:-$POD_REPO/lib/primer}"

# single source of the color palette (pod-add-worker + the MCP both read it)
POD_PALETTE="${POD_PALETTE:-$POD_REPO/lib/palette}"

export POD_BIN POD_REPO POD_TMUX POD_TMUX_SOCKET POD_TMUX_DEDICATED POD_TMP POD_STATE POD_INBOX POD_COMMS \
  POD_SESSION_PREFIX POD_CITIES POD_MANAGER_NAME POD_MANAGER_NAME_AUTO POD_MANAGER_CARD POD_MANAGER_CMD POD_STAR_AWARDER \
  POD_FOREIGN_INTERVAL POD_FOREIGN_TRIM POD_CONFIG_DIR POD_CONFIG \
  POD_ADAPTERS_DIR POD_USER_ADAPTERS POD_SLOTS POD_MODULES POD_PALETTE \
  POD_OPERATOR_MEMORY POD_PRIMER_DIR

# convenience: pod-adapter is the single TOML query tool; everything else calls it.
POD_ADAPTER="${POD_ADAPTER:-$POD_BIN/pod-adapter}"
export POD_ADAPTER

# one safe path component (mirrors _pod-common.sh's pod_sanitize; duplicated here so
# path-only consumers don't have to pull in the comms layer).
pod_path_component() { LC_ALL=C printf '%s' "${1:-$POD_SESSION_PREFIX}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'; }

# Conservative one-component identifiers used for pod names, task ids and template
# names. This simultaneously prevents namespace collisions and path traversal.
pod_valid_component() {
  case "${1:-}" in
    [A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 128 ]
}

# --- portability helpers (jq is OPTIONAL on every model-facing path) ---------------
# pod_json_get <file> <key> — one top-level field from a small JSON file. jq when
# present, else python3. Empty output + rc 0 on any failure, so callers keep their
# existing `[ -n ... ]` guards.
pod_json_get() {
  [ -f "${1:-}" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "${2:-}" '.[$k] // empty' "$1" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "${2:-}" <<'PY' 2>/dev/null
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    v = None
if v is not None and v is not False:
    sys.stdout.write(str(v) + "\n")   # newline parity with `jq -r`
PY
  fi
  return 0
}

# pod_emit_ctx <hookEventName> <text> — additionalContext JSON for a lifecycle hook.
# This is why jq must stay optional here: on a machine without jq, every model-facing
# injection (roster, journal, podmate deltas, pod-mail) would silently vanish while
# the deck itself looks healthy — agents blind, state dots fine. Chain: jq -> python3
# (a hard dep of hooks/*/install.sh) -> raw stdout (SessionStart and UserPromptSubmit
# inject plain stdout as context too, so even the last resort lands).
pod_emit_ctx() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg e "${1:-}" --arg c "${2:-}" \
      '{hookSpecificOutput:{hookEventName:$e, additionalContext:$c}}'
  elif command -v python3 >/dev/null 2>&1; then
    POD_CTX_E="${1:-}" POD_CTX_C="${2:-}" python3 -c \
      'import json,os;print(json.dumps({"hookSpecificOutput":{"hookEventName":os.environ["POD_CTX_E"],"additionalContext":os.environ["POD_CTX_C"]}}))'
  else
    printf '%s\n' "${2:-}"
  fi
  return 0
}

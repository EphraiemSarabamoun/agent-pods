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
# tmux binary. Empty config -> resolve on PATH (no platform-specific hardcode).
POD_TMUX="${POD_TMUX:-$(command -v tmux 2>/dev/null || echo tmux)}"

# tmp roots: one tree, three subdirs.
#   state/  workers.json, tmux_group.json, log.jsonl, dispatched/<pod>/,
#           completed/<pod>/, *.pid, *.log
#   inbox/  <task-id>/{prompt.txt,result.json,DONE}, _queue/<pod>/, _templates/
#   comms/  <pod>/{channel.log, <wid>.mbox, <wid>.read, work/}            (pod-comms)
POD_TMP="${POD_TMP:-${TMPDIR:-/tmp}/agent-pods-$(/usr/bin/id -u)}"

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
/bin/mkdir -p "$POD_TMP" "$POD_STATE" "$POD_INBOX" "$POD_COMMS" 2>/dev/null || {
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
case "$(/usr/bin/uname -s 2>/dev/null)" in
  Darwin) __pod_owner="$(/usr/bin/stat -f '%u' "$POD_TMP" 2>/dev/null || true)" ;;
  *)      __pod_owner="$(/usr/bin/stat -c '%u' "$POD_TMP" 2>/dev/null || true)" ;;
esac
if [ -n "$__pod_owner" ] && [ "$__pod_owner" != "$(/usr/bin/id -u)" ]; then
  printf 'pod: runtime root is owned by uid %s, not %s: %s\n' "$__pod_owner" "$(/usr/bin/id -u)" "$POD_TMP" >&2
  unset __pod_owner
  return 1 2>/dev/null || exit 1
fi
/bin/chmod 700 "$POD_TMP" "$POD_STATE" "$POD_INBOX" "$POD_COMMS" 2>/dev/null || true
unset __pod_owner

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

export POD_BIN POD_REPO POD_TMUX POD_TMP POD_STATE POD_INBOX POD_COMMS \
  POD_SESSION_PREFIX POD_CITIES POD_MANAGER_NAME POD_MANAGER_NAME_AUTO POD_MANAGER_CARD POD_MANAGER_CMD POD_STAR_AWARDER \
  POD_FOREIGN_INTERVAL POD_FOREIGN_TRIM POD_CONFIG_DIR POD_CONFIG \
  POD_ADAPTERS_DIR POD_USER_ADAPTERS POD_SLOTS POD_MODULES POD_PALETTE \
  POD_OPERATOR_MEMORY POD_PRIMER_DIR

# convenience: pod-adapter is the single TOML query tool; everything else calls it.
POD_ADAPTER="${POD_ADAPTER:-$POD_BIN/pod-adapter}"
export POD_ADAPTER

# --- sandbox portability: the tmux socket is an UPGRADE, files are the truth --------
# Some environments run the agent's subprocesses in a command sandbox that denies
# unix-socket connect (CI runners, containers, restricted shells). There the tmux
# client->server socket is unreachable from hook subprocesses (connect() -> EPERM)
# even though the server is alive and the pane is genuinely in a pod. Every fallback
# below gates on this ONE probe: socket reachable -> behave exactly as always (zero
# behavior change); socket unreachable -> the file paths take over.
# Memoized per process so hot-path hooks probe at most once.
pod_socket_ok() {
  if [ -z "${__POD_SOCKET_OK:-}" ]; then
    __POD_SOCKET_OK=0
    if [ -n "${TMUX:-}" ]; then
      if [ -n "${TMUX_PANE:-}" ]; then
        "$POD_TMUX" display-message -p -t "$TMUX_PANE" ok >/dev/null 2>&1 && __POD_SOCKET_OK=1
      else
        "$POD_TMUX" display-message -p ok >/dev/null 2>&1 && __POD_SOCKET_OK=1
      fi
    fi
  fi
  [ "$__POD_SOCKET_OK" = 1 ]
}

# pod_require_socket [<action name>] — a REACTIVE sandbox notice for commands that
# genuinely change the tmux deck (spawn/kill a worker, toggle FULL AUTO). When the
# socket is reachable it's a silent pass; when it's blocked it explains, to stderr,
# that this action needs the socket the sandbox denies and what still works instead,
# then returns 1 so the caller can bail with a clear message rather than a cryptic
# tmux error. Read/exchange commands (pod, pod-tell, pod-mail, pod-note) do NOT call
# this — they work from files and must stay silent.
pod_require_socket() {
  # Probe SERVER reachability, pane-INDEPENDENTLY — deliberately NOT via pod_socket_ok
  # (which is keyed to $TMUX_PANE, for in-pane hooks). External callers — a script, the
  # MCP, the test harness — target a pod by session name from outside any pane, where
  # $TMUX_PANE belongs to a different server or is unset; they must NOT trip this. A
  # reachable server (list-sessions succeeds) means proceed, in every one of those cases.
  "$POD_TMUX" list-sessions >/dev/null 2>&1 && return 0
  # Unreachable AND we're inside a tmux pane -> a command sandbox is blocking connect().
  # (Outside tmux with no reachable server isn't the sandbox case: let the command's own
  # tmux call error naturally rather than blaming a sandbox.)
  [ -n "${TMUX:-}" ] || return 0
  printf 'pod: %s needs the tmux socket, which is blocked in this command sandbox.\n' "${1:-this action}" >&2
  printf '     Deck-changing features (spawn/kill workers, send keys to a pane, toggle FULL AUTO)\n' >&2
  printf '     are unavailable from a sandboxed seat. What DOES work here: pod (roster), pod-tell /\n' >&2
  printf '     pod-mail, pod-note, and your own state dots. Run pod-doctor for the full picture.\n' >&2
  return 1
}

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

# where a sandboxed seat's hooks MIRROR the per-window state they cannot stamp onto
# tmux ( <win> = "state ts agent_id" · <win>.work = "ts\ttext" · <win>.last =
# "ts\tdigest\ttranscript" ). The unsandboxed pod-foreign-state poller reconciles
# these files back onto the real tmux options, so the strip/roster/badge render
# paths stay untouched. Data flows agent -> file -> poller -> tmux, never
# sandboxed-agent -> socket.
pod_mirror_dir() { printf '%s/mirror/%s' "$POD_STATE" "$(pod_path_component "${1:-${POD_SESSION:-}}")"; }

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

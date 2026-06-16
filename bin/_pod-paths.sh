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
#   state/  workers.json, tmux_group.json, log.jsonl, *.pid, *.log
#   inbox/  <task-id>/{prompt.txt,result.json,DONE}, _queue/, _templates/  (queue module)
#   comms/  <pod>/{channel.log, <wid>.mbox, <wid>.read, work/}            (pod-comms)
POD_TMP="${POD_TMP:-/tmp/pod}"

# deck identity (agent-agnostic: the manager defaults to a plain shell, not any one agent).
POD_SESSION_PREFIX="${POD_SESSION_PREFIX:-pod}"
# city-name pool for NEW pods (pod-city). Empty -> pod-city's built-in list. A
# space-separated list of single-word names overrides it; exhaustion falls back to
# the numeric <prefix>-N series.
POD_CITIES="${POD_CITIES:-}"
POD_MANAGER_NAME="${POD_MANAGER_NAME:-manager}"
# When FULL AUTO is on, pod-auto renames the manager window to this (to signal the
# mode). Defaults to POD_MANAGER_NAME, so the rename is a visible no-op unless you
# set a distinct name. (The private deck uses e.g. "Claudius" / "Claudius Maximus".)
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

# adapters: repo defaults, then user overrides (~/.config/pod/adapters/*.toml win by
# basename — handled by pod-adapter, which globs both with user last).
POD_ADAPTERS_DIR="${POD_ADAPTERS_DIR:-$POD_REPO/adapters}"
POD_USER_ADAPTERS="${POD_USER_ADAPTERS:-$POD_CONFIG_DIR/adapters}"
# the 10 quick-pick "+" slots: JSON (install-generated + edited via the gear menu, not
# hand-authored prose — so JSON, not TOML). The agent CATALOG is the rich TOML.
POD_SLOTS="${POD_SLOTS:-$POD_CONFIG_DIR/slots.json}"
POD_MODULES="${POD_MODULES:-$POD_REPO/modules}"

# single source of the color palette (pod-add-worker + the MCP both read it)
POD_PALETTE="${POD_PALETTE:-$POD_REPO/lib/palette}"

export POD_BIN POD_REPO POD_TMUX POD_TMP POD_STATE POD_INBOX POD_COMMS \
  POD_SESSION_PREFIX POD_CITIES POD_MANAGER_NAME POD_MANAGER_NAME_AUTO POD_MANAGER_CARD POD_MANAGER_CMD POD_STAR_AWARDER \
  POD_FOREIGN_INTERVAL POD_FOREIGN_TRIM POD_CONFIG_DIR POD_CONFIG \
  POD_ADAPTERS_DIR POD_USER_ADAPTERS POD_SLOTS POD_MODULES POD_PALETTE

# convenience: pod-adapter is the single TOML query tool; everything else calls it.
POD_ADAPTER="${POD_ADAPTER:-$POD_BIN/pod-adapter}"
export POD_ADAPTER

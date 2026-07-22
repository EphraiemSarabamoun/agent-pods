#!/usr/bin/env bash
# _mgr-runtime.sh — shared runtime helpers for the FULL AUTO switch and the
# queue/MCP dispatch path. SOURCE it; do not execute. bash 3.2 safe.
#
# This is the MINIMAL cut: pod resolution, manager-window resolution, and the
# FULL AUTO gate. (A fuller manager would also carry assignment-lease helpers; the
# bundled queue module tracks worker availability via workers.json status instead,
# so leases are intentionally absent here.)
[ -n "${__MGR_RUNTIME_LOADED:-}" ] && return 0
__MGR_RUNTIME_LOADED=1

__mr_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
[ -n "${POD_TMUX:-}" ] || . "$__mr_dir/_pod-paths.sh"
. "$__mr_dir/_pod-common.sh"      # pod_name, pod_dir_for, pod_chan_for
unset __mr_dir
MGR_TMUX="${POD_TMUX:-$(command -v tmux 2>/dev/null || echo tmux)}"

# Resolve the caller's pod: live pane session, else inherited POD_SESSION env, else
# the recorded primary pod, else the configured prefix.
mgr_current_pod() {
  local sess=""
  if [ -n "${TMUX_PANE:-}" ]; then
    sess="$("$MGR_TMUX" display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)"
  fi
  [ -n "$sess" ] || sess="${POD_SESSION:-}"
  if [ -z "$sess" ]; then
    sess="$(pod_json_get "$POD_STATE/tmux_group.json" pod)"
    [ -n "$sess" ] || sess="$(pod_json_get "$POD_STATE/tmux_group.json" session)"
  fi
  printf '%s' "${sess:-$POD_SESSION_PREFIX}"
}

# Window id of a pod's manager (window 0). Prefer the @pod_manager_win stamp; fall
# back to the index-0 window. Note the "=${sess}:" target form: show-options errors
# "no such session" on the bare "=name" form on tmux 3.6b (list-windows accepts it).
mgr_manager_window() {
  local sess="$1" win
  win="$("$MGR_TMUX" show-options -t "=${sess}:" -qv @pod_manager_win 2>/dev/null)"
  if [ -z "$win" ]; then
    win="$("$MGR_TMUX" list-windows -t "=$sess" -F '#{window_id}|#{window_index}' 2>/dev/null \
      | awk -F'|' '$2==0{print $1; exit}')"
  fi
  printf '%s' "$win"
}

# A pod's FULL AUTO switch (the strip's ⚡ AUTO / ✋ MAN pill, session option
# @full_auto, flipped by pod-auto): prints on | off | none.
#   none = NOT a stamped pod (no live session, or @is_pod unset). Callers MUST treat
#   none as unrestricted (fail-OPEN), so a plain tmux session or a headless seat
#   behaves exactly as it would without the switch. Only a session stamped @is_pod=1
#   with @full_auto!=1 forbids automatic dispatch.
mgr_pod_auto_state() {
  local sess="$1"
  "$MGR_TMUX" has-session -t "=$sess" 2>/dev/null || { printf 'none'; return; }
  [ "$("$MGR_TMUX" show-options -t "=${sess}:" -qv @is_pod 2>/dev/null)" = "1" ] \
    || { printf 'none'; return; }
  if [ "$("$MGR_TMUX" show-options -t "=${sess}:" -qv @full_auto 2>/dev/null)" = "1" ]; then
    printf 'on'
  else
    printf 'off'
  fi
}

# Succeeds unless automatic dispatch is forbidden (a stamped pod with the switch off).
mgr_full_auto() { [ "$(mgr_pod_auto_state "$1")" != "off" ]; }

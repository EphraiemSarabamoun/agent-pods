#!/usr/bin/env bash
# _pod-common.sh — shared layout + helpers for pod-comms (pod-tell, pod-mail,
# pod-mail-check, pod-deliver, pod-kill-worker, pod-mail-gc). SOURCE it.
#
# Comms are PER-POD, under $POD_COMMS (set by _pod-paths.sh):
#   $POD_COMMS/<pod>/channel.log         the chat feed pod-summary renders
#   $POD_COMMS/<pod>/<window_id>.mbox    a recipient's unread mailbox
#   $POD_COMMS/<pod>/<window_id>.read    its read archive
#   $POD_COMMS/<pod>/<window_id>.hw      pod-deliver high-water (lines already notified)
#   $POD_COMMS/<pod>/work/<window_id>.log  pod-work headlines
#
# <pod> is the tmux session name. The whole <pod> subtree is deleted when the pod
# closes (pod-launch sets a session-closed hook -> pod-mail-gc) and swept on launch if
# it went stale. Route every pod-comms path through THESE helpers. bash 3.2 safe.
[ -n "${__POD_COMMON_LOADED:-}" ] && return 0
__POD_COMMON_LOADED=1

# make sure POD_COMMS / POD_TMUX / POD_SESSION_PREFIX exist (idempotent).
if [ -z "${POD_COMMS:-}" ]; then
  __cdir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  . "$__cdir/_pod-paths.sh"
  unset __cdir
fi
POD_TMUX="${POD_TMUX:-$(command -v tmux 2>/dev/null || echo tmux)}"

# sanitize a pod name into one safe path component (never empty).
pod_sanitize() { LC_ALL=C printf '%s' "${1:-$POD_SESSION_PREFIX}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'; }

pod_dir_for()  { printf '%s/%s' "$POD_COMMS" "$(pod_sanitize "$1")"; }
pod_chan_for() { printf '%s/channel.log' "$(pod_dir_for "$1")"; }

# current pod (tmux session) from the calling pane, else inherited env, else the prefix.
pod_name() {
  local s=""
  if [ -n "${TMUX:-}" ]; then
    s="$("$POD_TMUX" display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)"
  fi
  [ -n "$s" ] || s="${POD_SESSION:-$POD_SESSION_PREFIX}"
  printf '%s' "$s"
}

pod_mbox() { printf '%s/%s.mbox' "$(pod_dir_for "$(pod_name)")" "$1"; }
pod_read() { printf '%s/%s.read' "$(pod_dir_for "$(pod_name)")" "$1"; }

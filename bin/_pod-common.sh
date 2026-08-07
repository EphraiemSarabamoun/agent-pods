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

# mtime of a path as a plain integer (0 when unknown). BSD and GNU stat share NO
# format flag, and the classic `stat -f %m x || stat -c %Y x` chain is a trap: on GNU
# coreutils -f means "filesystem status", so it treats %m as a FILENAME, prints a
# multi-line filesystem dump for the real path on STDOUT and exits 1 — the caller's
# command substitution keeps that dump, and the next `$(( now - mtime ))` dies with
# "File: unbound variable" under set -u. Branch on uname (memoized) like
# _pod-paths.sh:118 already does, then scrub the answer to digits.
pod_file_mtime() {
  local m=""
  [ -n "${__POD_UNAME:-}" ] || __POD_UNAME="$(uname -s 2>/dev/null)"
  case "$__POD_UNAME" in
    Darwin) m="$(stat -f %m "${1:-}" 2>/dev/null)" ;;
    *)      m="$(stat -c %Y "${1:-}" 2>/dev/null)" ;;
  esac
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

# Neutralize a message body before it is appended to a LINE-DELIMITED comms file.
# Every consumer treats one line as one message (pod-mail-check counts '^\[',
# pod-deliver's high-water is a line count, pod-feed parses one record per line), so a
# newline inside a body forges extra messages attributed to a podmate — inside another
# agent's model context, which makes it a straight prompt-injection channel between
# seats. Newlines become the two-character escape \n: the body stays complete and
# readable wherever it is rendered, but it can never become a second record. Other C0
# controls (and DEL) are dropped; the tr ranges touch bytes < 0x80 only, so UTF-8 and
# emoji pass through untouched.
pod_msg_oneline() {
  printf '%s' "${1:-}" \
    | LC_ALL=C tr -d '\001-\010\013-\037\177' \
    | LC_ALL=C awk 'NR>1{printf "%s", "\\n"} {printf "%s", $0}'
}

# Where pod-sync-pod-name leaves a forwarding record for a rename: one file per OLD
# pod name whose contents are the NEW one.
pod_rename_record() { printf '%s/renames/%s' "$POD_STATE" "$(pod_sanitize "${1:-}")"; }

# Resolve a pod name that came from $POD_SESSION rather than from a live tmux answer.
# $POD_SESSION is a SPAWN-TIME snapshot: a pod rename migrates the whole comms subtree
# out from under it and a RUNNING pane never sees the updated session env, so a caller
# with no live tmux answer would otherwise read and write a ghost of the pre-rename pod
# forever — mail delivered to the live dir and never read, notes landing in a directory
# the next launch sweeps. Follow the forwarding trail.
pod_resolve_stale_pod() {
  local cur="${1:-}" nxt="" rec="" hops=0
  while [ "$hops" -lt 8 ]; do
    # A comms subtree under this name wins outright: the name is in use RIGHT NOW (a
    # new pod may legitimately re-use a retired name), so never forward off it.
    [ -d "$(pod_dir_for "$cur")" ] && break
    rec="$(pod_rename_record "$cur")"
    [ -f "$rec" ] || break
    nxt=""; IFS= read -r nxt < "$rec" 2>/dev/null || true
    { [ -n "$nxt" ] && [ "$nxt" != "$cur" ]; } || break
    cur="$nxt"; hops=$((hops + 1))
  done
  printf '%s' "$cur"
}

# current pod (tmux session) from the calling pane, else inherited env, else the prefix.
pod_name() {
  local s=""
  if [ -n "${TMUX:-}" ]; then
    s="$("$POD_TMUX" display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)"
  fi
  # No live answer: POD_SESSION is only a snapshot, so validate it against the rename
  # trail before trusting it.
  [ -n "$s" ] || s="$(pod_resolve_stale_pod "${POD_SESSION:-$POD_SESSION_PREFIX}")"
  printf '%s' "$s"
}

pod_mbox() { printf '%s/%s.mbox' "$(pod_dir_for "$(pod_name)")" "$1"; }
pod_read() { printf '%s/%s.read' "$(pod_dir_for "$(pod_name)")" "$1"; }

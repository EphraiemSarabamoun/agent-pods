#!/usr/bin/env bash
# Claude Code SessionStart hook — POD AWARENESS.
#
# Tells a Claude Code instance which pod it is in and who its podmates are, so
# every instance starts aware of the others in its tmux session. Silent if the
# instance is not running inside a pod (no tmux). Never fails session start.
#
# It ALSO stamps this window authoritatively as Claude Code: @agent_id=claude-code,
# @pod_native_delivery=1, @state_source=hooks. That tells the foreign-state poller to
# leave this window's state dot alone (Claude drives it via pod-state) and tells
# pod-deliver to surface pod-mail as additionalContext instead of typing into the pane.
#
# Resolves the pod bin from $POD_BIN if exported, else from this hook's own location
# (hooks/claude-code/ -> repo root -> bin/). bash 3.2 safe.
set -u

command -v tmux >/dev/null 2>&1 || exit 0
[ -n "${TMUX:-}" ] || exit 0

# --- resolve POD_BIN (env wins; else derive from this file's location) -----------
if [ -n "${POD_BIN:-}" ] && [ -x "$POD_BIN/pod" ]; then
  :
else
  # this file lives at <repo>/hooks/claude-code/pod-awareness.sh -> bin is ../../bin
  HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
  POD_BIN="$(cd "$HOOK_DIR/../../bin" 2>/dev/null && pwd)"
fi
[ -n "${POD_BIN:-}" ] && [ -x "$POD_BIN/pod" ] || exit 0

T="$(command -v tmux 2>/dev/null || echo tmux)"

# --- stamp this window as Claude Code (authoritative) ----------------------------
# The pane this hook runs in is the Claude window; @state_source=hooks keeps the
# foreign poller off it, @pod_native_delivery=1 makes pod-deliver skip send-keys.
WIN="$("$T" display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null)"
if [ -n "$WIN" ]; then
  "$T" set-option -w -t "$WIN" @agent_id           "claude-code" 2>/dev/null || true
  "$T" set-option -w -t "$WIN" @pod_native_delivery 1            2>/dev/null || true
  "$T" set-option -w -t "$WIN" @state_source        "hooks"      2>/dev/null || true
fi

# --- emit the roster as additionalContext ----------------------------------------
OUT="$(bash "$POD_BIN/pod" 2>/dev/null)"
case "$OUT" in
  *instance\(s\):*) : ;;   # a real roster ("POD '...' — N instance(s):")
  *) exit 0 ;;             # not in a pod, or the degraded "no windows found" message
esac

MSG="Pod awareness: you share a pod (tmux session) with other agent instances, so you are not alone.

$OUT

Run 'pod' anytime to refresh this roster. A POD is the live cluster of co-located agent instances in this tmux session."

# SessionStart injects into the MODEL's context via hookSpecificOutput.additionalContext.
# A top-level systemMessage only prints in the user's terminal and the model never sees it.
command -v jq >/dev/null 2>&1 && jq -n --arg c "$MSG" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
exit 0

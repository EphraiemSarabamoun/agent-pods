#!/usr/bin/env bash
# check-workflow-state.sh — a seat that launched a background workflow must not read
# idle until that workflow finishes.
#
# The regression this guards: pod-state's Stop/Notification paths stamp idle the
# moment a turn ends, but Claude Code's Workflow tool returns immediately and its
# agents grind on in the background — so the seat went green (and became eligible
# for dispatch, mail submits and star delivery) mid-workflow. pod-workflow-state
# records launches from the PostToolUse payload; pod-state consults it before every
# idle stamp. Liveness comes from the workflow's own journal.jsonl: an agent with a
# `started` and no `result` is in flight.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SOCK="pod-wfstate-$$"
TMUX_BIN="$(command -v tmux)"
trap '"$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { echo "  ok: $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $*" >&2; fail=$((fail + 1)); }
check() { desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "check-workflow-state: python3 required" >&2; exit 1; }
[ -n "$TMUX_BIN" ] || { echo "check-workflow-state: tmux required" >&2; exit 1; }

# isolated tmux server via a single-path wrapper (the POD_TMUX pin opts out of the
# dedicated-socket shim, so every script targets exactly this server)
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$TMUX_BIN" "$SOCK" > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
PT="$TMP/bin/tmux"

"$PT" new-session -d -s Wf -n seat 'sleep 100'
"$PT" set -t Wf @is_pod 1
PANE="$("$PT" display-message -p -t Wf:0 '#{pane_id}')"
WIN="$("$PT" display-message -p -t Wf:0 '#{window_id}')"
WSAFE="$(printf '%s' "$WIN" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
REG="$TMP/runtime/comms/Wf/wf/${WSAFE}.list"

wfs() {  # run pod-workflow-state as the seat's own hook would
  TMUX=1 TMUX_PANE="$PANE" POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
    "$REPO/bin/pod-workflow-state" "$@"
}
stamp() {  # run pod-state as the seat's own hook would
  TMUX=1 TMUX_PANE="$PANE" POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
    "$REPO/bin/pod-state" "$@" </dev/null
}
dot() { "$PT" show-options -w -t "$WIN" -qv @cc_state 2>/dev/null; }

# --- record: the PostToolUse payload lands in this window's registry ------------
mkdir -p "$TMP/run1"
printf '%s' "{\"tool_name\":\"Workflow\",\"tool_response\":{\"status\":\"async_launched\",\"runId\":\"wf_test1\",\"transcriptDir\":\"$TMP/run1\"}}" | wfs record
check "record registers the launched workflow" test -s "$REG"
check "record captures the runId" grep -q "wf_test1" "$REG"

# a foreign tool's payload must not register anything
printf '%s' '{"tool_name":"Bash","tool_response":{"runId":"wf_bogus"}}' | wfs record
if grep -q wf_bogus "$REG" 2>/dev/null; then
  bad "non-Workflow tool payloads are ignored"
else
  ok "non-Workflow tool payloads are ignored"
fi

# --- in flight: a started agent with no result pins the seat busy ---------------
printf '%s\n' '{"type":"started","agentId":"a1"}' > "$TMP/run1/journal.jsonl"
touch -t 202601010101 "$TMP/run1/journal.jsonl"   # stale mtime must NOT beat in-flight
check "check reports in-flight while an agent is unfinished" wfs check
stamp busy
stamp idle
check "idle stamp is suppressed to busy mid-workflow" test "$(dot)" = busy

# --- finished: balanced journal + stale mtime frees the seat --------------------
printf '%s\n' '{"type":"result","agentId":"a1"}' >> "$TMP/run1/journal.jsonl"
touch -t 202601010101 "$TMP/run1/journal.jsonl"   # older than the quiescence grace
if wfs check; then
  bad "balanced stale journal reads as finished"
else
  ok "balanced stale journal reads as finished"
fi
check "finished workflow clears its registry" test ! -e "$REG"
stamp idle
check "idle stamp lands once the workflow is done" test "$(dot)" = idle

# Every terminal journal event balances a started agent. A failed/cancelled child
# is finished work, not an immortal workflow that pins the seat orange for two hours.
mkdir -p "$TMP/run2"
printf '%s' "{\"tool_name\":\"Workflow\",\"tool_response\":{\"status\":\"async_launched\",\"runId\":\"wf_test2\",\"transcriptDir\":\"$TMP/run2\"}}" | wfs record
printf '%s\n' '{"type":"started","agentId":"a2"}' '{"type":"failed","agentId":"a2"}' > "$TMP/run2/journal.jsonl"
touch -t 202601010101 "$TMP/run2/journal.jsonl"
if wfs check; then
  bad "failed terminal event leaves workflow in flight"
else
  ok "failed terminal event completes the workflow"
fi
check "failed workflow clears its registry" test ! -e "$REG"

# --- reset: a fresh process owns nothing its predecessor launched ---------------
mkdir -p "$(dirname "$REG")"
printf 'wf_stale\t%s\t%s\n' "$TMP/run1/journal.jsonl" "$(date +%s)" > "$REG"
printf '%s' '{"source":"compact"}' | wfs reset
check "compact reset preserves the live process registry" test -e "$REG"
wfs reset
check "reset drops the inherited registry" test ! -e "$REG"

# --- crash backstop: a recorded run whose journal never appears dies by grace ---
old_epoch="$(( $(date +%s) - 600 ))"   # far past STARTUP_GRACE, journal absent
printf 'wf_ghost\t%s\t%s\n' "$TMP/never-written/journal.jsonl" "$old_epoch" > "$REG"
if wfs check; then
  bad "journal-less run beyond startup grace reads as finished"
else
  ok "journal-less run beyond startup grace reads as finished"
fi
check "dead journal-less run clears its registry" test ! -e "$REG"

# a JUST-launched run with no journal yet stays alive (startup grace)
printf 'wf_fresh\t%s\t%s\n' "$TMP/never-written/journal.jsonl" "$(date +%s)" > "$REG"
check "fresh journal-less run stays in flight" wfs check

echo "check-workflow-state: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

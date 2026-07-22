#!/usr/bin/env bash
# check-sandbox-fallback.sh — the command-sandbox acceptance tests.
#
# Simulates the environment that motivated the file-fallback tier: an agent whose
# subprocesses CANNOT connect to the tmux socket (every tmux call fails), while the
# pod's files (workers.json, tmux_group.json, journal, mailboxes) are readable. The
# seat carries its spawn-time identity env (POD_WINDOW / POD_AGENT_ID / POD_SESSION).
#
# Asserts, per the spec:
#   sandboxed: bin/pod prints a REAL file-backed roster (not "no windows found");
#              pod-awareness emits JSON whose additionalContext contains the roster;
#              pod-brief boot injects the journal tail; refresh emits journal deltas;
#              pod-state writes the mirror file (posttool contract preserved);
#              pod-tell deposits mail from the registry table; pod-mail-check drains
#              the mailbox and emits it as context.
#   normal:    with a WORKING socket and an empty window list, bin/pod still says
#              "no windows found" (ghost-resurrection guard) and pod-state uses
#              set-option, never the mirror file.
# No real tmux needed. bash 3.2 safe.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
note() { echo "check-sandbox-fallback: $*" >&2; }
ok()   { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*"; fails=$((fails + 1)); }

command -v python3 >/dev/null 2>&1 || { note "python3 required"; exit 1; }

# --- stub tmux: MODE=blocked -> every call fails (socket EPERM); MODE=live ->
# answers identity probes, records set-options, returns an EMPTY window list.
STUB="$TMP/tmux-stub"
cat > "$STUB" <<'EOF'
#!/bin/sh
[ -n "${STUB_LOG:-}" ] && echo "$*" >> "$STUB_LOG"
[ "${STUB_MODE:-blocked}" = "blocked" ] && exit 1
case "${1:-}" in
  display-message)
    case "$*" in
      *"#{window_id}"*)    echo "@9" ;;
      *"#{session_name}"*) echo "testpod" ;;
      *) echo ok ;;
    esac ;;
  list-windows|show-options) : ;;   # empty output, exit 0
esac
exit 0
EOF
chmod +x "$STUB"
# the stub must ALSO be on PATH as `tmux`: the real sandbox has the tmux BINARY on
# PATH (only the socket is blocked), and several hooks gate on `command -v tmux`.
mkdir -p "$TMP/bin"; cp "$STUB" "$TMP/bin/tmux"; chmod +x "$TMP/bin/tmux"

# --- fixtures ---------------------------------------------------------------------
PODTMP="$TMP/pod"
mkdir -p "$PODTMP/state" "$PODTMP/comms/testpod"
cat > "$PODTMP/state/tmux_group.json" <<'EOF'
{ "session": "testpod", "pod": "testpod", "manager_window": "@0", "tmux_bin": "tmux", "host": "testhost" }
EOF
cat > "$PODTMP/state/workers.json" <<'EOF'
{ "workers": [
  { "tmux_session": "testpod", "tmux_window": "@2", "label": "Daisy", "card": "Claude Code · test", "agent_id": "claude-code" },
  { "tmux_session": "testpod", "tmux_window": "@3", "label": "Ivy",   "card": "Claude Code · test", "agent_id": "claude-code" },
  { "tmux_session": "otherpod", "tmux_window": "@8", "label": "Ghost", "card": "x", "agent_id": "claude-code" }
] }
EOF
printf '[10:00] NOTE (Daisy): first journal line\n[10:01] Ivy · busy · doing things\n' \
  > "$PODTMP/comms/testpod/journal.md"

# run a pod script under the sandboxed env. $1=STUB_MODE, rest = command
runenv() {
  mode="$1"; shift
  env -i PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin" HOME="$TMP" \
    TMUX="/tmp/fake,1,0" TMUX_PANE="%7" \
    POD_TMUX="$STUB" STUB_MODE="$mode" STUB_LOG="${STUB_LOG:-}" \
    POD_TMP="$PODTMP" POD_CONFIG=/dev/null \
    POD_SESSION=testpod POD_WINDOW="${AS_WINDOW:-@2}" POD_AGENT_ID=claude-code \
    "$@"
}

ctx_of() {  # extract additionalContext from hook JSON on stdin (empty on failure)
  python3 -c 'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception: pass'
}

# --- 1. sandboxed roster ------------------------------------------------------------
out="$(runenv blocked bash "$REPO/bin/pod")"
case "$out" in
  *"instance(s):"*Daisy*Ivy*)
    case "$out" in
      *Ghost*) bad "file roster leaked a worker from another pod" ;;
      *) ok "bin/pod: file-backed roster (instances, no cross-pod leak)" ;;
    esac ;;
  *"no windows found"*) bad "bin/pod hit the no-windows dead-end under a blocked socket" ;;
  *) bad "bin/pod roster unexpected: $(printf '%s' "$out" | head -2)" ;;
esac
case "$out" in *"<-- you"*) ok "bin/pod: self-marking via POD_WINDOW" ;; *) bad "no '<-- you' marker from POD_WINDOW" ;; esac

# --- 2. sandboxed awareness hook ------------------------------------------------------
ctx="$(runenv blocked bash "$REPO/hooks/claude-code/pod-awareness.sh" claude-code | ctx_of)"
case "$ctx" in
  *"instance(s):"*Ivy*) ok "pod-awareness: JSON additionalContext carries the roster" ;;
  *) bad "pod-awareness emitted no usable roster context" ;;
esac

# --- 3. sandboxed journal boot + refresh delta ------------------------------------------
ctx="$(runenv blocked bash "$REPO/bin/pod-brief" boot | ctx_of)"
case "$ctx" in
  *"first journal line"*) ok "pod-brief boot: journal tail injected from disk" ;;
  *) bad "pod-brief boot missed the journal" ;;
esac
runenv blocked bash "$REPO/bin/pod-brief" refresh UserPromptSubmit >/dev/null   # arms cursor
printf '[10:05] Ivy · idle · finished the thing\n' >> "$PODTMP/comms/testpod/journal.md"
ctx="$(runenv blocked bash "$REPO/bin/pod-brief" refresh UserPromptSubmit | ctx_of)"
case "$ctx" in
  *"finished the thing"*) ok "pod-brief refresh: journal delta since last turn" ;;
  *) bad "pod-brief refresh emitted no journal delta" ;;
esac

# --- 4. sandboxed state mirror -----------------------------------------------------------
runenv blocked bash "$REPO/bin/pod-state" busy </dev/null
MF="$PODTMP/state/mirror/testpod/@2"
if [ -f "$MF" ] && grep -q '^busy ' "$MF"; then ok "pod-state: mirror file written (busy)"; else bad "pod-state mirror missing/wrong: $(cat "$MF" 2>/dev/null)"; fi
ts1="$(awk '{print $2}' "$MF")"
sleep 1
runenv blocked bash "$REPO/bin/pod-state" busy </dev/null
[ "$(awk '{print $2}' "$MF")" = "$ts1" ] && ok "pod-state: same-state re-fire keeps the transition ts" \
  || bad "pod-state: ts churned on a non-transition"
runenv blocked bash "$REPO/bin/pod-state" busy posttool </dev/null
grep -q '^busy ' "$MF" && ok "pod-state: posttool no-op preserved outside wait" || bad "posttool misbehaved"
printf 'wait %s claude-code\n' "$(date +%s)" > "$MF"
runenv blocked bash "$REPO/bin/pod-state" busy posttool </dev/null
grep -q '^busy ' "$MF" && ok "pod-state: posttool rescues a stuck wait via the mirror" || bad "posttool failed to rescue wait"

# --- 5. sandboxed send + receive ------------------------------------------------------------
runenv blocked bash "$REPO/bin/pod-tell" Ivy "hello from the sandbox" >/dev/null 2>&1
MBOX="$PODTMP/comms/testpod/@3.mbox"
if grep -q 'Daisy: hello from the sandbox' "$MBOX" 2>/dev/null; then
  ok "pod-tell: deposit via registry table, sender named from POD_WINDOW"
else
  bad "pod-tell deposit failed: $(cat "$MBOX" 2>/dev/null)"
fi
ctx="$(AS_WINDOW=@3 runenv blocked bash "$REPO/bin/pod-mail-check" UserPromptSubmit | ctx_of)"
case "$ctx" in
  *"hello from the sandbox"*) ok "pod-mail-check: mail lands in additionalContext" ;;
  *) bad "pod-mail-check delivered nothing" ;;
esac
[ ! -s "$MBOX" ] && ok "pod-mail-check: mailbox drained" || bad "mailbox not drained"
grep -q 'hello from the sandbox' "$PODTMP/comms/testpod/@3.read" 2>/dev/null \
  && ok "pod-mail-check: archived to .read" || bad "mail not archived"

# --- 6. normal-path guards --------------------------------------------------------------------
rm -rf "$PODTMP/state/mirror"
out="$(runenv live bash "$REPO/bin/pod")"
case "$out" in
  *"no windows found"*) ok "ghost guard: WORKING socket + empty window list stays a dead pod" ;;
  *) bad "ghost resurrection: file roster fired on a working socket: $(printf '%s' "$out" | head -1)" ;;
esac
LOG="$TMP/stub.log"; : > "$LOG"
STUB_LOG="$LOG" runenv live bash "$REPO/bin/pod-state" busy </dev/null
grep -q 'set-option -w -t @9 @cc_state busy' "$LOG" && ok "normal pod-state: set-option via socket" \
  || bad "normal pod-state did not set-option: $(cat "$LOG")"
[ ! -d "$PODTMP/state/mirror" ] && ok "normal pod-state: no mirror file written" \
  || bad "normal path wrote a mirror file"

if [ "$fails" -gt 0 ]; then note "$fails failure(s)"; exit 1; fi
note "all checks passed"
exit 0

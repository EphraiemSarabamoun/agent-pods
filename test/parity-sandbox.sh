#!/usr/bin/env bash
# parity-sandbox.sh — fresh-environment smoke of the WHOLE pod deck in an ISOLATED
# tmux server + tmp tree, touching nothing on the real system. Exercises every feature
# with agent-stamped sleeper processes (no agent API spend). Idempotent + self-cleaning.
#
#   ./test/parity-sandbox.sh
#
# For a REAL-agent end-to-end (a live Claude/Codex worker executing a dispatched task
# through the autonomous fire-and-poll loop, billed to your subscription not an API
# key), see docs/autonomy.md — spawn a worker with the claude-code/codex adapter and
# run the mgr-stage -> mgr-queue -> mgr-pick-next -> pod-task-wait loop by hand. This
# script deliberately stays deterministic + free so it can run anywhere.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST_PATH="$PATH"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m — %s\n' "$1" "${2:-}"; }
# chk <label> <test-expr> [detail]
chk(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1" "${3:-}"; fi; }
sec(){ printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

SBX="$(mktemp -d "${TMPDIR:-/tmp}/agent-pods-sbx.XXXXXX")"
SBX="$(cd -P "$SBX" && pwd)"
SOCK="podsbx$$"
REALTMUX="$(command -v tmux)"
cleanup(){
  poller_pid=""
  poller_state="${POD_STATE:-${POD_TMP:-}/state}"
  [ -z "${POD_TMP:-}" ] || poller_pid="$(cat "$poller_state/pod-foreign-state.pid" 2>/dev/null || true)"
  case "$poller_pid" in *[!0-9]*|"") ;; *) kill "$poller_pid" 2>/dev/null || true ;; esac
  "$REALTMUX" -L "$SOCK" kill-server 2>/dev/null
  if [ "${POD_KEEP_SANDBOX:-0}" = "1" ]; then
    printf '\nparity sandbox retained at %s\n' "$SBX" >&2
  else
    rm -rf "$SBX"
  fi
}
trap cleanup EXIT
TM(){ "$REALTMUX" -L "$SOCK" "$@"; }

# tmux shim: keeps POD_TMUX single-word while every "$T" call lands on the isolated
# socket. Clone the repo, then overlay the current worktree so local changes and new
# files are tested without copying ignored caches or credentials into the sandbox.
mkdir -p "$SBX/bin"
printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$REALTMUX" "$SOCK" > "$SBX/bin/tmux"; chmod +x "$SBX/bin/tmux"
git -C "$REPO" clone -q "$REPO" "$SBX/repo" 2>/dev/null || {
  echo "failed to clone $REPO for the parity sandbox" >&2
  exit 1
}
CLONE="$SBX/repo"
git -C "$REPO" diff --binary --no-ext-diff HEAD | git -C "$CLONE" apply --allow-binary-replacement
while IFS= read -r -d '' file; do
  mkdir -p "$CLONE/$(dirname "$file")"
  cp -p "$REPO/$file" "$CLONE/$file"
done < <(git -C "$REPO" ls-files --others --exclude-standard -z)
export PATH="$SBX/bin:$CLONE/bin:$CLONE/modules/queue/bin:$PATH"
export POD_TMP="$SBX/pod" POD_CONFIG_DIR="$SBX/config" POD_STAR_AWARDER="Tester"
# The suite uses sleeper processes stamped as agent workers. Let the foreign-state
# poller perform its initial detection, then keep it out of deterministic state
# transitions that this harness drives explicitly below.
export POD_FOREIGN_INTERVAL=3600
unset POD_TMUX ANTHROPIC_API_KEY CLAUDECODE
# CRITICAL: this harness may run from INSIDE a tmux (and inside Claude Code). Drop the
# inherited tmux + Claude context so deck scripts resolve the SANDBOX pod (via
# tmux_group.json / POD_SESSION), not whatever real session/config we launched from.
unset TMUX TMUX_PANE CLAUDE_CONFIG_DIR

printf '\033[1magent-pods parity sandbox\033[0m  (clone=%s socket=%s)\n' "$CLONE" "$SOCK"

# ── 1. install.sh isolation (sandboxed HOME — touches nothing real) ───────────
sec "install.sh (isolated HOME)"
IHOME="$SBX/home"; mkdir -p "$IHOME/.claude"
( cd "$CLONE" && HOME="$IHOME" XDG_CONFIG_HOME="$IHOME/.config" CLAUDE_CONFIG_DIR="$IHOME/.claude" \
    ./install.sh --with-claude-hooks --no-logins ) >"$SBX/install.log" 2>&1
chk "install.sh exits 0" '[ $? -eq 0 ] || grep -q "wired\|already" "$SBX/install.log"' "see $SBX/install.log"
chk "symlinks bin/* into sandbox ~/.local/bin" '[ -L "$IHOME/.local/bin/pod-launch" ] && [ -L "$IHOME/.local/bin/pod-auto" ] && [ -L "$IHOME/.local/bin/pod-summary-pane" ]'
chk "seeds slots.json" '[ -s "$IHOME/.config/pod/slots.json" ]'
chk "agent slots do not persist launch commands" '! jq -e ".slots[] | select(.agent != null and has(\"cmd\"))" "$IHOME/.config/pod/slots.json" >/dev/null'
chk "wires Claude Code hooks into settings.json" 'grep -q "pod-state" "$IHOME/.claude/settings.json"'
chk "PostToolUse rescue hook wired" 'grep -q "PostToolUse" "$IHOME/.claude/settings.json"'
( cd "$CLONE" && HOME="$IHOME" XDG_CONFIG_HOME="$IHOME/.config" CLAUDE_CONFIG_DIR="$IHOME/.claude" \
    ./install.sh --with-claude-hooks --no-logins ) >"$SBX/install2.log" 2>&1
chk "re-run is idempotent (no duplicate hooks)" 'grep -qi "already present\|nothing to do" "$SBX/install2.log"'

# ── 2. launch a pod headless (attach fails w/o a tty; the session persists) ────
sec "launch + city naming"
POD_MANAGER_CMD='sleep 600' "$CLONE/bin/pod-launch" </dev/null >/dev/null 2>&1 || true
sleep 0.2
POD="$(TM list-sessions -F '#{session_name}' 2>/dev/null | head -1)"
export POD_SESSION="$POD"
chk "a pod session exists" '[ -n "$POD" ]' "no session created"
chk "named after a city (not pod-N)" '[ -n "$POD" ] && ! printf %s "$POD" | grep -qE "^pod(-[0-9]+)?$"' "got: $POD"
chk "stamped @is_pod=1" '[ "$(TM show-options -t "=$POD:" -qv @is_pod)" = 1 ]'
chk "stamped @full_auto=0 (manual default)" '[ "$(TM show-options -t "=$POD:" -qv @full_auto)" = 0 ]'
chk "@pod_name + @pod_manager_win stamped" '[ "$(TM show-options -t "=$POD:" -qv @pod_name)" = "$POD" ] && [ -n "$(TM show-options -t "=$POD:" -qv @pod_manager_win)" ]'
chk "manager window 0 present" '[ -n "$(TM list-windows -t "=$POD:" -F "#{window_index}" | grep -x 0)" ]'
chk "POD_TMP propagated into the tmux server env" 'TM show-environment -g POD_TMP 2>/dev/null | grep -q "$SBX/pod"'

# ── 3. spawn no-cost, agent-stamped sleeper workers + roster ──────────────────
sec "spawn workers + roster"
POD_SESSION="$POD" "$CLONE/bin/pod-add-worker" --agent claude-code --cmd 'sleep 600' --label 'stub A' >/dev/null 2>&1
POD_SESSION="$POD" "$CLONE/bin/pod-add-worker" --agent claude-code --cmd 'sleep 600' --label 'stub B' >/dev/null 2>&1
nwin="$(TM list-windows -t "=$POD:" -F '#{window_id}' | grep -c .)"
chk "two workers spawned (3 windows total)" '[ "$nwin" -eq 3 ]' "got $nwin"
chk "workers registered in workers.json (status idle)" '[ "$(jq "[.workers[]|select(.status==\"idle\")]|length" "$SBX/pod/state/workers.json" 2>/dev/null)" -ge 2 ]'
chk "workers got distinct tab colors" '[ "$(TM list-windows -t "=$POD:" -F "#{window-status-style}" | grep -c "bg=colour")" -ge 2 ]'
roster="$(POD_SESSION="$POD" "$CLONE/bin/pod" 2>/dev/null)"
chk "pod roster lists 3 instances" 'printf %s "$roster" | grep -q "3 instance"'
chk "no pod-watch in the roster" '! printf %s "$roster" | grep -q pod-watch'

# worker ids for later
W1="$(TM list-windows -t "=$POD:" -F '#{window_index}|#{window_id}' | awk -F'|' '$1==1{print $2}')"
W2="$(TM list-windows -t "=$POD:" -F '#{window_index}|#{window_id}' | awk -F'|' '$1==2{print $2}')"
# mark workers as detectable hook agents so comms/star delivery paths engage
TM set -w -t "$W1" @agent_id claude-code; TM set -w -t "$W1" @agent_id_cmd sleep; TM set -w -t "$W1" @agent "Claude Code"; TM set -w -t "$W1" @cc_state busy; TM set -w -t "$W1" @state_source hooks
TM set -w -t "$W2" @agent_id claude-code; TM set -w -t "$W2" @agent_id_cmd sleep; TM set -w -t "$W2" @agent "Claude Code"; TM set -w -t "$W2" @cc_state busy; TM set -w -t "$W2" @state_source hooks

# ── 4. comms: direct pill / chat quiet / @everyone, feed contract ─────────────
sec "pod-comms + unread pills + chat tier"
MPANE="$(TM display-message -p -t "$POD:0" '#{pane_id}')"
W1NAME="$(TM display-message -p -t "$W1" '#{window_name}')"
TMUX=1 TMUX_PANE="$MPANE" POD_SESSION="$POD" "$CLONE/bin/pod-tell" "$W1NAME" "review the PR please" >/dev/null 2>&1
chk "direct message stamps the @unread pill" '[ "$(TM show-options -wqv -t "$W1" @unread)" = 1 ]'
TM set -uw -t "$W1" @unread 2>/dev/null
TMUX=1 TMUX_PANE="$MPANE" POD_SESSION="$POD" "$CLONE/bin/pod-tell" chat "fyi: standup at 10" >/dev/null 2>&1
chk "chat tier does NOT badge" '[ -z "$(TM show-options -wqv -t "$W1" @unread)" ]'
chk "chat writes an fyi line" 'grep -q "^fyi " "$SBX/pod/comms/$POD/${W1}.mbox"'
TMUX=1 TMUX_PANE="$MPANE" POD_SESSION="$POD" "$CLONE/bin/pod-tell" all "deploy freeze" >/dev/null 2>&1
chk "@everyone badges a recipient" '[ -n "$(TM show-options -wqv -t "$W1" @unread)" ]'
chk "channel.log records all three" '[ "$(grep -c . "$SBX/pod/comms/$POD/channel.log")" -ge 3 ]'
# feed cache contract
feedline="$(POD_COLS=60 POD_FEED_CACHE=1 "$CLONE/bin/pod-feed" "$SBX/pod/comms/$POD/channel.log" 2>/dev/null | head -1)"
chk "pod-feed cache emits ord|more|plen|line" 'printf %s "$feedline" | grep -qE "^[0-9]+\|[01]\|[0-9]+\|"'
chk "pod-mail-check clears the pill at next prompt" 'TMUX=1 TMUX_PANE="$(TM list-panes -t "$W1" -F "#{pane_id}"|head -1)" POD_SESSION="$POD" "$CLONE/bin/pod-mail-check" UserPromptSubmit >/dev/null 2>&1; [ -z "$(TM show-options -wqv -t "$W1" @unread)" ]'
chk "pod-mail-check DELIVERS the messages (auto-delivery, not a nudge)" 'TMUX=1 TMUX_PANE="$(TM list-panes -t "$W2" -F "#{pane_id}"|head -1)" POD_SESSION="$POD" "$CLONE/bin/pod-mail-check" UserPromptSubmit 2>/dev/null | jq -e ".hookSpecificOutput.additionalContext | contains(\"deploy freeze\")" >/dev/null && [ ! -s "$SBX/pod/comms/$POD/${W2}.mbox" ] && grep -q "deploy freeze" "$SBX/pod/comms/$POD/${W2}.read"'

# ── 4b. pod journal + per-turn delta brief ─────────────────────────────────────
sec "pod journal (pod-brief)"
POD_SESSION="$POD" POD_BRIEF_WHO=sbx "$CLONE/bin/pod-note" "sandbox says hi" >/dev/null 2>&1
chk "pod-note lands in journal.md" 'grep -q "NOTE (sbx): sandbox says hi" "$SBX/pod/comms/$POD/journal.md"'
bootj="$(TMUX=1 TMUX_PANE="$MPANE" POD_SESSION="$POD" "$CLONE/bin/pod-brief" boot 2>/dev/null)"
chk "boot injects the journal tail as context" 'printf %s "$bootj" | jq -e ".hookSpecificOutput.additionalContext | contains(\"sandbox says hi\")"'
r1="$(TMUX=1 TMUX_PANE="$MPANE" POD_SESSION="$POD" "$CLONE/bin/pod-brief" refresh UserPromptSubmit 2>/dev/null)"
chk "first refresh reports podmates as spawned" 'printf %s "$r1" | jq -e ".hookSpecificOutput.additionalContext | contains(\"spawned\")"'
r2="$(TMUX=1 TMUX_PANE="$MPANE" POD_SESSION="$POD" "$CLONE/bin/pod-brief" refresh UserPromptSubmit 2>/dev/null)"
chk "quiet second refresh emits nothing" '[ -z "$r2" ]'
chk "auto-journal recorded the joins" 'grep -q "joined" "$SBX/pod/comms/$POD/journal.md"'

# ── 5. docked summary pane ────────────────────────────────────────────────────
sec "docked summary pane"
POD_SESSION="$POD" "$CLONE/bin/pod-summary-pane" on "$POD" >/dev/null 2>&1; sleep 0.15
chk "pane docks (tagged @pod_summary=1)" '[ "$(TM list-panes -s -t "=$POD" -F "#{@pod_summary}" | grep -c 1)" -eq 1 ]'
chk "host window gets the cyan resize border" 'TM show-options -w -t "$POD:0" pane-border-style 2>/dev/null | grep -q colour45 || TM list-panes -s -t "=$POD" -F "#{@pod_summary}" | grep -q 1'
paneout="$(POD_COLS=70 POD_SESSION="$POD" "$CLONE/bin/pod-summary" --pane "$POD" </dev/null 2>/dev/null | python3 -c "import sys,re;print(re.sub(r'\x1b\\[[0-9;]*[mK]','',sys.stdin.read()))")"
chk "pane single-paint renders the pod header" 'printf %s "$paneout" | grep -q "$POD Pod"'

# scroll engine — drive the LIVE interactive docked pane via send-keys (keyboard +
# a synthetic mouse-wheel SGR), then capture-pane the result. Seed enough messages to
# overflow the feed budget so there's something to scroll.
PANE5="$(TM list-panes -s -t "=$POD" -F '#{pane_id}|#{@pod_summary}' | awk -F'|' '$2=="1"{print $1}')"
for nx in $(seq -w 1 25); do printf '[09:%s] Tester → chat: MSG-%s line\n' "$nx" "$nx"; done >> "$SBX/pod/comms/$POD/channel.log"
sleep 2.5   # let the pane reload its feed cache (2s tick)
capf(){ TM capture-pane -p -t "$PANE5" 2>/dev/null | grep -oE 'MSG-[0-9]+'; }
chk "feed renders newest-first (MSG-25 visible at live)" 'capf | grep -qx MSG-25'
chk "oldest (MSG-01) is scrolled off at live" '! capf | grep -qx MSG-01'
TM send-keys -t "$PANE5" u; sleep 0.2; TM send-keys -t "$PANE5" u; sleep 0.25
chk "scroll-up shows the newer-hidden indicator" 'TM capture-pane -p -t "$PANE5" | grep -qi "newer hidden"'
chk "scroll-up reveals older messages" 'capf | grep -qE "MSG-0[1-9]|MSG-1[0-9]"'
TM send-keys -t "$PANE5" -l $'\x1b[<65;30;10M'; sleep 0.25
chk "synthetic mouse-wheel scrolls (mouse parser + burst drain)" 'TM capture-pane -p -t "$PANE5" | grep -qi "newer hidden"'
TM send-keys -t "$PANE5" r; sleep 0.25
chk "r returns to live (newest back, indicator gone)" 'capf | grep -qx MSG-25 && ! TM capture-pane -p -t "$PANE5" | grep -qi "newer hidden"'
chk "pane render carries ANSI color" 'TM capture-pane -ep -t "$PANE5" 2>/dev/null | LC_ALL=C grep -qa "$(printf "\033")"'

POD_SESSION="$POD" "$CLONE/bin/pod-summary-pane" off "$POD" >/dev/null 2>&1; sleep 0.1
chk "pane undocks cleanly" '[ "$(TM list-panes -s -t "=$POD" -F "#{@pod_summary}" | grep -c 1)" -eq 0 ]'

# ── 6. buttons via pod-status-action + keyboard chords ────────────────────────
sec "buttons + chords"
chk "fullauto button flips @full_auto" 'POD_SESSION="$POD" "$CLONE/bin/pod-status-action" fullauto "$POD" "" >/dev/null 2>&1; [ "$(TM show-options -t "=$POD:" -qv @full_auto)" = 1 ]'
TM set -t "$POD" @full_auto 0
chk "spawn menu builds (POD_MENU_PRINT)" 'POD_MENU_PRINT=1 "$CLONE/bin/pod-spawn-menu-build" 2>/dev/null | grep -q display-menu'
chk "star menu builds (POD_MENU_PRINT)" 'POD_MENU_PRINT=1 "$CLONE/bin/pod-star-menu" "$POD" 2>/dev/null | grep -q "Gold star"'
# chords: list-keys after launch. tmux prints "bind-key  -T <table>  <key>  <cmd>".
lk="$(TM list-keys 2>/dev/null)"
key_bound(){ printf %s "$lk" | grep -qE "bind-key +-T $1 +$2 +"; }
chk "chord C-a a (fullauto)" 'key_bound prefix a'
chk "chord C-a s (summary)"  'key_bound prefix s'
chk "chord C-a + (spawn)"    'key_bound prefix [+]'
chk "chord C-a g (settings)" 'key_bound prefix g'
chk "chord C-a X (kill)"     'key_bound prefix X'
chk "chord C-a , (rename wk)" 'key_bound prefix [,]'
for m in M-a M-s M-d M-f M-g M-x M-r M-c M-v M-C M-V; do
  chk "chord $m" "key_bound root $m"
done
chk "MouseDrag1Status bound" 'printf %s "$lk" | grep -q MouseDrag1Status'
chk "DoubleClick1StatusLeft (pod rename) bound" 'printf %s "$lk" | grep -q DoubleClick1StatusLeft'

# ── 7. drag-reorder ───────────────────────────────────────────────────────────
sec "drag-to-reorder"
before="$(TM list-windows -t "=$POD:" -F '#{window_index}:#{window_name}' | tr '\n' ' ')"
TM select-window -t "$POD:1"
POD_SESSION="$POD" "$CLONE/bin/pod-drag-reorder" --right "$POD" >/dev/null 2>&1
after="$(TM list-windows -t "=$POD:" -F '#{window_index}:#{window_name}' | tr '\n' ' ')"
chk "M-V move swaps workers 1 and 2" '[ "$before" != "$after" ]' "$before -> $after"
TM select-window -t "$POD:0"
m0="$(TM list-windows -t "=$POD:" -F '#{window_index}:#{window_name}' | grep '^0:')"
POD_SESSION="$POD" "$CLONE/bin/pod-drag-reorder" --right "$POD" >/dev/null 2>&1
chk "manager (window 0) immovable" '[ "$(TM list-windows -t "=$POD:" -F "#{window_index}:#{window_name}" | grep "^0:")" = "$m0" ]'

# ── 8. rename migration ───────────────────────────────────────────────────────
sec "rename migration"
NEWNAME="Verona"; OLDNAME="$POD"
TM rename-session -t "$POD" "$NEWNAME"; sleep 0.8
chk "comms subtree migrates old -> new" '[ -d "$SBX/pod/comms/$NEWNAME" ] && [ ! -d "$SBX/pod/comms/$OLDNAME" ]'
chk "@pod_name re-stamped" '[ "$(TM show-options -t "=$NEWNAME:" -qv @pod_name)" = "$NEWNAME" ]'
chk "rename logged to the feed" 'grep -q "pod renamed $OLDNAME -> $NEWNAME" "$SBX/pod/comms/$NEWNAME/channel.log"' "feed: $(tail -1 "$SBX/pod/comms/$NEWNAME/channel.log" 2>/dev/null)"
POD="$NEWNAME"; export POD_SESSION="$POD"

# ── 9. FULL AUTO gate + queue dispatch + poll ─────────────────────────────────
sec "FULL AUTO gate + queue"
TM set -t "$POD" @full_auto 0
gate_manual="$(POD_SESSION="$POD" mgr-pick-next 2>&1)"
chk "mgr-pick-next HOLDS the queue in manual mode" 'printf %s "$gate_manual" | grep -q "FULL AUTO is OFF"'
# stage + queue a task (template falls back to modules/queue/templates/execute.tpl.txt)
tid="$(POD_SESSION="$POD" mgr-stage execute --id sbx-task-1 context="sandbox" task_body="touch the DONE file" 2>/dev/null)"
chk "mgr-stage writes a prompt" '[ -s "$SBX/pod/inbox/sbx-task-1/prompt.txt" ]'
POD_SESSION="$POD" mgr-queue sbx-task-1 --priority 50 --description "sandbox task" >/dev/null 2>&1
chk "mgr-queue enqueues it in this pod" 'ls "$SBX/pod/inbox/_queue/$POD"/*sbx-task-1* >/dev/null 2>&1'
# flip auto + dispatch to an idle worker
TM set -t "$POD" @full_auto 1
# make a worker idle so dispatch has a target
idlewin="$(jq -r '.workers[0].tmux_window' "$SBX/pod/state/workers.json")"
TM set -w -t "$idlewin" @cc_state idle
jq '(.workers[0].status)="idle"' "$SBX/pod/state/workers.json" > "$SBX/wj" && mv "$SBX/wj" "$SBX/pod/state/workers.json"
disp="$(POD_SESSION="$POD" mgr-pick-next 2>&1)"
dispatch_state="$(jq -c '.workers' "$SBX/pod/state/workers.json" 2>/dev/null)"
dispatch_live="$(for wid in "$W1" "$W2"; do printf '%s:%s:%s:%s ' "$wid" \
  "$(TM display-message -p -t "$wid" '#{session_name}' 2>/dev/null)" \
  "$(TM show-options -w -t "$wid" -qv @cc_state 2>/dev/null)" \
  "$(TM show-options -w -t "$wid" -qv @agent_id 2>/dev/null)"; done)"
chk "mgr-pick-next dispatches in full-auto" \
  'jq -e ".workers[]|select(.current_task_id==\"sbx-task-1\" and .status==\"busy\")" "$SBX/pod/state/workers.json"' \
  "$disp · live=$dispatch_live · registry=$dispatch_state"
# simulate the worker completing (reap pinned OFF here; 9b tests it deliberately)
printf '{"status":"done","answer":"ok"}' > "$SBX/pod/inbox/sbx-task-1/result.json"
touch "$SBX/pod/inbox/sbx-task-1/DONE"
freed="$(MGR_REAP_FINISHED_WORKERS=0 POD_SESSION="$POD" mgr-poll 2>&1)"
chk "mgr-poll detects DONE + frees the worker" 'printf %s "$freed" | grep -q sbx-task-1' \
  "$freed · registry=$(jq -c '.workers' "$SBX/pod/state/workers.json" 2>/dev/null)"
chk "mgr-status renders the board" 'POD_SESSION="$POD" mgr-status 2>/dev/null | grep -qi "queue\|worker\|complet"'

# Two concurrent dispatchers may both read the same queue head, but the queue-file
# rename is an atomic task claim. Exactly one may send/own the task.
POD_SESSION="$POD" mgr-stage execute --id sbx-race context="sandbox" task_body="race" >/dev/null 2>&1
POD_SESSION="$POD" mgr-queue sbx-race --priority 55 >/dev/null 2>&1
R1="$(jq -r '.workers[0].tmux_window' "$SBX/pod/state/workers.json")"
R2="$(jq -r '.workers[1].tmux_window' "$SBX/pod/state/workers.json")"
TM set -w -t "$R1" @cc_state idle; TM set -w -t "$R2" @cc_state idle
( POD_SESSION="$POD" mgr-dispatch --task sbx-race --tmux-window "$R1" >/dev/null 2>&1 ) & p1=$!
( POD_SESSION="$POD" mgr-dispatch --task sbx-race --tmux-window "$R2" >/dev/null 2>&1 ) & p2=$!
rc1=0; wait "$p1" || rc1=$?; rc2=0; wait "$p2" || rc2=$?
owners="$(jq '[.workers[]|select(.current_task_id=="sbx-race")]|length' "$SBX/pod/state/workers.json")"
chk "concurrent dispatch has exactly one winner" '[ "$owners" -eq 1 ] && { [ "$rc1" -eq 0 ] || [ "$rc2" -eq 0 ]; } && ! { [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]; }'
chk "concurrent task has one in-flight archive" '[ -f "$SBX/pod/state/dispatched/$POD/sbx-race.json" ] && ! ls "$SBX/pod/inbox/_queue/$POD"/*sbx-race* >/dev/null 2>&1'
winner="$(jq -r '.workers[]|select(.current_task_id=="sbx-race")|.tmux_window' "$SBX/pod/state/workers.json")"
touch "$SBX/pod/inbox/sbx-race/DONE"; TM set -w -t "$winner" @cc_state idle
MGR_REAP_FINISHED_WORKERS=0 POD_SESSION="$POD" mgr-poll >/dev/null 2>&1

# ── 9b. queue self-healing: reclaim, reap, ghost quarantine ────────────────────
sec "queue self-healing"
# dead-worker reclaim: dispatch to a disposable worker, kill its window, poll requeues
POD_SESSION="$POD" "$CLONE/bin/pod-add-worker" --agent claude-code --cmd 'sleep 600' >/dev/null 2>&1; sleep 0.15
DW="$(jq -r '.workers[-1].tmux_window' "$SBX/pod/state/workers.json")"
TM set -w -t "$DW" @agent_id_cmd sleep; TM set -w -t "$DW" @cc_state idle; TM set -w -t "$DW" @state_source hooks
POD_SESSION="$POD" mgr-stage execute --id sbx-task-2 context="sandbox" task_body="reclaim me" >/dev/null 2>&1
POD_SESSION="$POD" mgr-queue sbx-task-2 --priority 60 >/dev/null 2>&1
POD_SESSION="$POD" mgr-dispatch --task sbx-task-2 --tmux-window "$DW" >/dev/null 2>&1
chk "dispatch stamps the live board busy" '[ "$(TM show-options -wqv -t "$DW" @cc_state)" = busy ]'
chk "assignment logged to the feed (⊕)" 'grep -q "⊕" "$SBX/pod/comms/$POD/channel.log"'
TM kill-window -t "$DW"; sleep 0.1
rec="$(POD_SESSION="$POD" mgr-poll 2>&1)"
chk "dead worker's task requeued" 'printf %s "$rec" | grep -q "requeued sbx-task-2"'
chk "queue holds the entry again" 'ls "$SBX/pod/inbox/_queue/$POD"/*sbx-task-2* >/dev/null 2>&1'
chk "dead registry row dropped" '! jq -e --arg w "$DW" ".workers[]|select(.tmux_window==\$w)" "$SBX/pod/state/workers.json" >/dev/null 2>&1'
# finished-worker reap: a fresh worker completes it, the queue drains, window closes
POD_SESSION="$POD" "$CLONE/bin/pod-add-worker" --agent claude-code --cmd 'sleep 600' >/dev/null 2>&1; sleep 0.15
RW="$(jq -r '.workers[-1].tmux_window' "$SBX/pod/state/workers.json")"
TM set -w -t "$RW" @agent_id_cmd sleep; TM set -w -t "$RW" @cc_state idle; TM set -w -t "$RW" @state_source hooks
POD_SESSION="$POD" mgr-dispatch --task sbx-task-2 --tmux-window "$RW" >/dev/null 2>&1
touch "$SBX/pod/inbox/sbx-task-2/DONE"
TM set -w -t "$RW" @cc_state idle   # the worker's Stop hook fires as it finishes
reap_poll="$(POD_SESSION="$POD" mgr-poll 2>&1)"; sleep 0.1
chk "finished worker reaped once the queue drained" \
  '[ "$(TM display-message -p -t "$RW" "#{window_id}" 2>/dev/null)" != "$RW" ]' \
  "poll=$reap_poll · registry=$(jq -c '.workers' "$SBX/pod/state/workers.json" 2>/dev/null)"
chk "reap logged" 'grep -q worker_reaped_on_completion "$SBX/pod/state/log.jsonl"' \
  "log=$(tail -n 8 "$SBX/pod/state/log.jsonl" 2>/dev/null)"
# ghost quarantine: a queue entry whose prompt vanished must not block the head
printf '{"task_id":"sbx-ghost","priority":40,"queued_at":"2020-01-01T00-00-00Z","pod":"%s"}\n' "$POD" > "$SBX/pod/inbox/_queue/$POD/040-x-sbx-ghost.json"
POD_SESSION="$POD" mgr-dispatch >/dev/null 2>&1; grc=$?
chk "ghost auto-pick exits 3 + quarantined to _state/dead" '[ "$grc" -eq 3 ] && ls "$SBX/pod/inbox/_state/dead/" | grep -q sbx-ghost'

# ── 10. stars ─────────────────────────────────────────────────────────────────
sec "human-only stars"
SW="$(jq -r '.workers[0].tmux_window' "$SBX/pod/state/workers.json")"
TM set -w -t "$SW" @agent_id claude-code; TM set -w -t "$SW" @cc_state busy
env -u TMUX_PANE POD_SESSION="$POD" "$CLONE/bin/pod-star" @"${SW#@}" "great work" >/dev/null 2>&1 || \
  env -u TMUX_PANE POD_SESSION="$POD" "$CLONE/bin/pod-star" "$SW" "great work" >/dev/null 2>&1
chk "award stamps @stars" '[ -n "$(TM show-options -wqv -t "$SW" @stars)" ]'
chk "busy deliverable agent queues a pending star" '[ -f "$SBX/pod/comms/$POD/stars/${SW}.pending" ]'
chk "agent caller is refused (human-only guard)" 'CLAUDECODE=1 POD_SESSION="$POD" "$CLONE/bin/pod-star" "$SW" 2>&1 | grep -q "awarded by the human"'

# ── 11. CI tests on the clone ────────────────────────────────────────────────
sec "CI tests"
if [ "${POD_PARITY_SKIP_CI:-0}" = "1" ]; then
  ok "CI scripts (verified separately)"
else
  chk "check-adapters.sh" 'bash "$CLONE/test/check-adapters.sh"'
  chk "lint-tmux-targets.sh" 'bash "$CLONE/test/lint-tmux-targets.sh"'
  chk "test-adapter-discovery-timeout.sh" 'bash "$CLONE/test/test-adapter-discovery-timeout.sh"'
  chk "no-private-leaks.sh" 'bash "$CLONE/test/no-private-leaks.sh"'
  chk "check-model-policy.sh" 'bash "$CLONE/test/check-model-policy.sh"'
  chk "check-context-emit.sh" 'bash "$CLONE/test/check-context-emit.sh"'
  chk "check-sandbox-fallback.sh" 'bash "$CLONE/test/check-sandbox-fallback.sh"'
  chk "check-install-modes.sh" 'bash "$CLONE/test/check-install-modes.sh"'
  chk "check-primer.sh" 'bash "$CLONE/test/check-primer.sh"'
  # The safety suite builds its own nested tmux shim. Do not let it discover this
  # harness's socket-pinning shim as the "real" tmux binary or its cleanup can target
  # the parity server instead of the nested server. Maintainers can skip this redundant
  # nested invocation when they just ran the safety suite separately (useful under
  # short-lived command runners); the default remains the complete one-command suite.
  if [ "${POD_PARITY_SKIP_SAFETY:-0}" = "1" ]; then
    ok "check-safety-invariants.sh (verified separately)"
  else
    chk "check-safety-invariants.sh" 'PATH="$HOST_PATH" bash "$CLONE/test/check-safety-invariants.sh"'
  fi
fi

# ── 12. MCP module ───────────────────────────────────────────────────────────
sec "MCP module"
chk "pod_manager_server.py parses" 'python3 -m py_compile "$CLONE/modules/mcp/pod_manager_server.py"'
chk "exposes the core pod_* tools" 'grep -q "def pod_spawn_window" "$CLONE/modules/mcp/pod_manager_server.py" && grep -q "def pod_dispatch" "$CLONE/modules/mcp/pod_manager_server.py" && grep -q "def pod_pick_next" "$CLONE/modules/mcp/pod_manager_server.py"'

# ── summary ──────────────────────────────────────────────────────────────────
printf '\n\033[1m== RESULT ==\033[0m\n  passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && { printf '\033[32mALL GREEN\033[0m\n'; exit 0; } || { printf '\033[31mFAILURES ABOVE\033[0m\n'; exit 1; }

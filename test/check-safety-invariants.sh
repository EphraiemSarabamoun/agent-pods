#!/usr/bin/env bash
# Regression coverage for isolation, containment, lock safety, and uninstall ownership.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SOCK="pod-safety-$$"
TMUX_BIN="$(command -v tmux)"
trap '"$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { echo "  ok: $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $*" >&2; fail=$((fail + 1)); }
check() { desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

# A single-path wrapper lets POD_TMUX target an isolated server.
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$TMUX_BIN" "$SOCK" > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
PT="$TMP/bin/tmux"

"$PT" new-session -d -s Alpha -n manager 'sleep 100'
"$PT" set -t Alpha @is_pod 1
AM="$("$PT" display-message -p -t Alpha:0 '#{window_id}')"
"$PT" set -t Alpha @pod_manager_win "$AM"
AW="$("$PT" new-window -d -t Alpha -n worker -P -F '#{window_id}' 'sleep 100')"
"$PT" new-session -d -s Beta -n manager 'sleep 100'
"$PT" set -t Beta @is_pod 1
BM="$("$PT" display-message -p -t Beta:0 '#{window_id}')"
BP="$("$PT" display-message -p -t Beta:0 '#{pane_id}')"
"$PT" set -t Beta @pod_manager_win "$BM"
BW="$("$PT" new-window -d -t Beta -n worker -P -F '#{window_id}' 'sleep 100')"

out="$(POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/bin/pod-kill-worker" "$BW" 2>&1)"; rc=$?
check "cross-pod kill is refused" test "$rc" -ne 0
check "cross-pod target remains alive" test "$("$PT" display-message -p -t "$BW" '#{window_id}')" = "$BW"

primer="$(TMUX=1 TMUX_PANE="$BP" POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Beta \
  "$REPO/bin/pod-primer" 2>/dev/null)"
check "secondary pod manager gets manager primer" grep -q 'primer (manager)' <<<"$primer"

if POD_TMP="$TMP/runtime" "$REPO/modules/queue/bin/mgr-stage" plan --id ../escape \
     context=x task_body=x >/dev/null 2>&1; then
  bad "path-traversing task id is rejected"
else
  ok "path-traversing task id is rejected"
fi
check "traversal wrote nothing outside inbox" test ! -e "$TMP/escape/prompt.txt"
if POD_TMP="$TMP/runtime" "$REPO/modules/queue/bin/mgr-stage" plan --id _queue \
     context=x task_body=x >/dev/null 2>&1; then
  bad "reserved inbox namespace is rejected as a task id"
else
  ok "reserved inbox namespace is rejected as a task id"
fi

# Known-agent quick picks must ignore a stale persisted command and resolve via the
# adapter when clicked.
mkdir -p "$TMP/config"
printf '%s\n' '{"slots":[{"label":"Claude stale","agent":"claude-code","model":"opus","effort":"high","cmd":"claude --model stale-id"}]}' > "$TMP/config/slots.json"
menu="$(POD_MENU_PRINT=1 POD_SLOTS="$TMP/config/slots.json" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-spawn-menu-build")"
check "quick-pick does not replay stale model command" sh -c '! printf %s "$1" | grep -q stale-id' sh "$menu"
check "quick-pick keeps semantic agent selection" grep -q -- '--agent claude-code' <<<"$menu"
check "quick-pick drops a stale persisted model label" sh -c '! printf %s "$1" | grep -q "Claude stale"' sh "$menu"
check "quick-pick does not stamp a precomputed agent label" sh -c '! printf %s "$1" | grep -q -- "--label"' sh "$menu"

# Shared registry helper: concurrent distinct claims must all survive.
mkdir -p "$TMP/state"
python3 - "$TMP/state/workers.json" <<'PY'
import json, sys
json.dump({"workers": [
    {"tmux_session": "Alpha", "tmux_window": f"@{i}", "status": "idle",
     "current_task_id": None, "started_at": None} for i in range(1, 31)
]}, open(sys.argv[1], "w"))
PY
pids=""
for i in $(seq 1 30); do
  "$REPO/bin/pod-workers-json" --path "$TMP/state/workers.json" claim "@$i" Alpha "t$i" now &
  pids="$pids $!"
done
claims_ok=1
for p in $pids; do wait "$p" || claims_ok=0; done
check "concurrent registry claims all complete" test "$claims_ok" -eq 1
check "concurrent registry claims lose no rows" test "$(jq '[.workers[]|select(.status=="busy")]|length' "$TMP/state/workers.json")" -eq 30

"$REPO/bin/pod-workers-json" --path "$TMP/state/workers.json" release @1 Alpha t1
check "exact release frees its own claim" test "$(jq -r '.workers[]|select(.tmux_window=="@1")|.status' "$TMP/state/workers.json")" = idle
check "exact release leaves another claim busy" test "$(jq -r '.workers[]|select(.tmux_window=="@2")|.status' "$TMP/state/workers.json")" = busy

printf '%s\n' '{"workers":[{"tmux_session":"Alpha","tmux_window":"@cas","status":"idle","current_task_id":null}]}' \
  > "$TMP/state/claim-cas.json"
"$REPO/bin/pod-workers-json" --path "$TMP/state/claim-cas.json" \
  claim @cas Alpha same-task old 1 old-token
"$REPO/bin/pod-workers-json" --path "$TMP/state/claim-cas.json" \
  release @cas Alpha same-task old-token
"$REPO/bin/pod-workers-json" --path "$TMP/state/claim-cas.json" \
  claim @cas Alpha same-task new 2 new-token
if "$REPO/bin/pod-workers-json" --path "$TMP/state/claim-cas.json" \
    release @cas Alpha same-task old-token >/dev/null 2>&1; then
  bad "stale recovery token cannot release a newer same-task claim"
else
  ok "stale recovery token cannot release a newer same-task claim"
fi
check "newer same-task claim survives stale release" sh -c \
  'jq -e '\''.workers[]|select(.claim_token=="new-token" and .status=="busy")'\'' "$1" >/dev/null' \
  sh "$TMP/state/claim-cas.json"

# Killing and dispatching race through one locked compare-and-delete. Exactly one
# operation may win: either the claim survives, or the idle row is removed before it
# can be claimed. A successful claim must never disappear.
drop_race_ok=1
for i in $(seq 1 12); do
  printf '%s\n' '{"workers":[{"tmux_session":"Alpha","tmux_window":"@race","status":"idle","current_task_id":null}]}' \
    > "$TMP/state/drop-race.json"
  "$REPO/bin/pod-workers-json" --path "$TMP/state/drop-race.json" \
    claim @race Alpha race-task now 1 >/dev/null 2>&1 & claim_pid=$!
  "$REPO/bin/pod-workers-json" --path "$TMP/state/drop-race.json" \
    drop-if-unassigned @race Alpha >/dev/null 2>&1 & drop_pid=$!
  claim_rc=0; wait "$claim_pid" || claim_rc=$?
  drop_rc=0; wait "$drop_pid" || drop_rc=$?
  if [ "$claim_rc" -eq 0 ] && [ "$drop_rc" -ne 0 ]; then
    jq -e '.workers[]|select(.current_task_id=="race-task")' \
      "$TMP/state/drop-race.json" >/dev/null || drop_race_ok=0
  elif [ "$drop_rc" -eq 0 ] && [ "$claim_rc" -ne 0 ]; then
    [ "$(jq '.workers|length' "$TMP/state/drop-race.json")" -eq 0 ] || drop_race_ok=0
  else
    drop_race_ok=0
  fi
done
check "assigned-worker drop is one locked compare-and-delete" test "$drop_race_ok" -eq 1

printf '%s\n' "{\"workers\":[{\"tmux_session\":\"Alpha\",\"tmux_window\":\"$AW\",\"status\":\"idle\"},{\"tmux_session\":\"Alpha\",\"tmux_window\":\"@99999\",\"status\":\"idle\"}]}" > "$TMP/state/prune.json"
"$REPO/bin/pod-workers-json" --path "$TMP/state/prune.json" prune "$PT"
check "registry prune preserves a live row" sh -c \
  'jq -e --arg w "$1" '\''.workers[]|select(.tmux_window==$w)'\'' "$2" >/dev/null' \
  sh "$AW" "$TMP/state/prune.json"
check "registry prune removes a stale row" test "$(jq '.workers|length' "$TMP/state/prune.json")" -eq 1

# The foreign-state singleton uses an atomic ownership lock. A concurrent second
# launch must exit without displacing the first poller.
POD_TMUX="$PT" POD_TMP="$TMP/poller-runtime" POD_FOREIGN_INTERVAL=10 \
  "$REPO/bin/pod-foreign-state" >/dev/null 2>&1 & poller1=$!
sleep 0.2
POD_TMUX="$PT" POD_TMP="$TMP/poller-runtime" POD_FOREIGN_INTERVAL=10 \
  "$REPO/bin/pod-foreign-state" >/dev/null 2>&1 & poller2=$!
wait "$poller2" 2>/dev/null
check "foreign-state singleton preserves the first poller" kill -0 "$poller1"
check "foreign-state singleton lock records its owner" test \
  "$(cat "$TMP/poller-runtime/state/pod-foreign-state.pid.lock/pid" 2>/dev/null)" = "$poller1"
kill "$poller1" 2>/dev/null || true
wait "$poller1" 2>/dev/null || true

# A wedged summarizer must be killed as a process group and return promptly.
printf '%s\n' '{"type":"assistant","message":{"content":"This is enough transcript content to exercise the configured summarizer timeout safely."}}' > "$TMP/transcript.jsonl"
"$PT" set-option -w -t "$AW" @transcript "$TMP/transcript.jsonl"
summarize_start="$(python3 -c 'import time; print(time.monotonic())')"
POD_TMUX="$PT" POD_TMP="$TMP/summarize-runtime" POD_SUMMARIZE_TIMEOUT=0.2 \
  POD_SUMMARIZE_CMD='sleep 5; echo late-output' \
  "$REPO/bin/pod-summarize" win "$AW" >/dev/null 2>&1
summarize_elapsed="$(python3 - "$summarize_start" <<'PY'
import sys, time
print(time.monotonic() - float(sys.argv[1]))
PY
)"
check "summarizer timeout returns promptly" python3 - "$summarize_elapsed" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1]) < 2.0 else 1)
PY
check "timed-out summarizer cannot stamp late output" test -z \
  "$("$PT" show-options -w -t "$AW" -qv @summary 2>/dev/null)"

# Two dispatchers racing for one queue entry may claim different workers before the
# queue-file mv arbitrates the task. The loser must release only its own claim.
A2="$($PT new-window -d -t Alpha -n worker2 -P -F '#{window_id}' 'sleep 100')"
for wid in "$AW" "$A2"; do
  "$PT" set-option -w -t "$wid" @cc_state idle
  "$PT" set-option -w -t "$wid" @agent_id claude-code
done
mkdir -p "$TMP/runtime/state"
printf '%s\n' "{\"workers\":[{\"tmux_session\":\"Alpha\",\"tmux_window\":\"$AW\",\"agent_id\":\"claude-code\",\"status\":\"idle\",\"current_task_id\":null},{\"tmux_session\":\"Alpha\",\"tmux_window\":\"$A2\",\"agent_id\":\"claude-code\",\"status\":\"idle\",\"current_task_id\":null}]}" > "$TMP/runtime/state/workers.json"
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-stage" execute --id race-task context=x task_body=x \
  constraints= output_schema= rollback_plan= scope= >/dev/null
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-queue" race-task >/dev/null
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-dispatch" --task race-task --tmux-window "$AW" >/dev/null 2>&1 & p1=$!
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-dispatch" --task race-task --tmux-window "$A2" >/dev/null 2>&1 & p2=$!
wait "$p1" 2>/dev/null || true
wait "$p2" 2>/dev/null || true
check "dispatch race leaves exactly one worker busy" test \
  "$(jq '[.workers[]|select(.status=="busy" and .current_task_id=="race-task")]|length' "$TMP/runtime/state/workers.json")" -eq 1
check "dispatch race releases the losing worker" test \
  "$(jq '[.workers[]|select(.status=="idle" and .current_task_id==null)]|length' "$TMP/runtime/state/workers.json")" -eq 1
check "dispatch archive is scoped to its pod" test -f "$TMP/runtime/state/dispatched/Alpha/race-task.json"

race_winner="$(jq -r '.workers[]|select(.current_task_id=="race-task")|.tmux_window' "$TMP/runtime/state/workers.json")"
if POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
    "$REPO/bin/pod-kill-worker" "$race_winner" >/dev/null 2>&1; then
  bad "assigned worker kill is refused"
else
  ok "assigned worker kill is refused"
fi
check "refused assigned worker remains alive" test \
  "$("$PT" display-message -p -t "$race_winner" '#{session_name}' 2>/dev/null)" = Alpha

# A sibling pod must not see Alpha's queue head.
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-stage" execute --id alpha-only context=x task_body=x \
  constraints= output_schema= rollback_plan= scope= >/dev/null
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-queue" alpha-only >/dev/null
beta_pick="$(POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Beta \
  "$REPO/modules/queue/bin/mgr-dispatch" 2>&1)"
check "sibling pod sees its own empty queue" grep -q "queue empty" <<<"$beta_pick"
check "sibling dispatch leaves Alpha queue untouched" sh -c \
  'ls "$1"/*alpha-only* >/dev/null 2>&1' sh "$TMP/runtime/inbox/_queue/Alpha"

# A brand-new pod has no scoped queue/archive directories yet. Status must still be
# valid JSON instead of failing under set -e/pipefail on an `ls` of a missing path.
mkdir -p "$TMP/empty-status/state"
printf '%s\n' '{"workers":[]}' > "$TMP/empty-status/state/workers.json"
empty_status="$(env -u TMUX -u TMUX_PANE POD_TMP="$TMP/empty-status" POD_SESSION=EmptyPod \
  "$REPO/modules/queue/bin/mgr-status" --json)"
check "empty pod status is valid and scoped" jq -e \
  '.pod=="EmptyPod" and .workers==[] and .queue_files==[]' <<<"$empty_status"

# The watcher sees DONE from the scoped dispatch archive, then keeps seeing the same
# task through the durable completion marker after mgr-poll removes that archive.
"$PT" set -t Alpha @full_auto 1
touch "$TMP/runtime/inbox/race-task/DONE"
wait_reason="$(POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  POD_TASK_WAIT_POLL=0.05 "$REPO/bin/pod-task-wait" 1)"
check "task watcher sees scoped DONE" test "$wait_reason" = idle-change
MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-poll" >/dev/null
wait_reason="$(POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  POD_TASK_WAIT_POLL=0.05 "$REPO/bin/pod-task-wait" 1)"
check "completion marker prevents a duplicate wake" test "$wait_reason" = timeout

# Turning AUTO back on may wake a paused manager only when its adapter proves the
# visible input is an empty placeholder. Stable human draft text must remain untouched.
mkdir -p "$TMP/runtime/state/pod-tasks"
printf '%s\n' '{"pod":"Alpha","status":"paused"}' > "$TMP/runtime/state/pod-tasks/Alpha.json"
"$PT" set -t Alpha @full_auto 0
"$PT" set-option -w -t "$AM" @cc_state idle
"$PT" set-option -w -t "$AM" @agent_id claude-code
"$PT" respawn-pane -k -t "$AM" "printf '%s\n' '❯ Try \"resume work\"'; sleep 100"
POD_AUTO_ANIM=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/bin/pod-auto" on --pod Alpha >/dev/null
manager_mail="$TMP/runtime/comms/Alpha/${AM}.mbox"
manager_hw="$TMP/runtime/comms/Alpha/${AM}.hw"
check "AUTO resume writes durable manager mail" grep -q "resume the paused pod-task" "$manager_mail"
check "AUTO resume nudges an idle manager" test \
  "$(cat "$manager_hw" 2>/dev/null)" = "$(awk 'END{print NR+0}' "$manager_mail")"
old_hw="$(cat "$manager_hw")"
printf '[00:00] full-auto switch: second safe test\n' >> "$manager_mail"
"$PT" respawn-pane -k -t "$AM" "printf '%s\n' '❯ human draft'; sleep 100"
POD_DELIVER_REQUIRE_EMPTY=1 POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-deliver" "$AM" --mode submit >/dev/null
check "AUTO resume does not submit over a stable human draft" test \
  "$(cat "$manager_hw")" = "$old_hw"

# Recover both SIGKILL windows before the archived dispatching marker exists.
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-stage" execute --id claim-before-move context=x task_body=x \
  constraints= output_schema= rollback_plan= scope= >/dev/null
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-queue" claim-before-move >/dev/null
premarker_worker="$(jq -r '.workers[]|select(.status=="idle")|.tmux_window' "$TMP/runtime/state/workers.json" | head -1)"
"$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
  claim "$premarker_worker" Alpha claim-before-move old 1 claim-before-token
MGR_DISPATCH_RECOVERY_SECONDS=0 MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" \
  POD_TMP="$TMP/runtime" POD_SESSION=Alpha "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "stale claim before queue move is released" test \
  "$(jq -r --arg w "$premarker_worker" '.workers[]|select(.tmux_window==$w)|.status' "$TMP/runtime/state/workers.json")" = idle
check "stale claim leaves its queued task intact" sh -c \
  'ls "$1"/*claim-before-move* >/dev/null 2>&1' sh "$TMP/runtime/inbox/_queue/Alpha"

POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-stage" execute --id move-before-marker context=x task_body=x \
  constraints= output_schema= rollback_plan= scope= >/dev/null
move_queue="$(POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-queue" move-before-marker)"
"$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
  claim "$premarker_worker" Alpha move-before-marker old 1 move-before-token
mkdir -p "$TMP/runtime/state/dispatched/Alpha"
mv "$move_queue" "$TMP/runtime/state/dispatched/Alpha/move-before-marker.json"
MGR_DISPATCH_RECOVERY_SECONDS=0 MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" \
  POD_TMP="$TMP/runtime" POD_SESSION=Alpha "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "stale queue move before marker is restored" sh -c \
  'ls "$1"/*move-before-marker* >/dev/null 2>&1' sh "$TMP/runtime/inbox/_queue/Alpha"
check "stale queue move releases its exact claim" test \
  "$(jq -r --arg w "$premarker_worker" '.workers[]|select(.tmux_window==$w)|.status' "$TMP/runtime/state/workers.json")" = idle

# A fenced dispatcher can wake late and move the queue record after recovery has
# already released its row. The status is still queued and no delivery was possible,
# so the orphan archive must be restored without needing a worker claim.
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-stage" execute --id orphan-queued context=x task_body=x \
  constraints= output_schema= rollback_plan= scope= >/dev/null
orphan_queue="$(POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-queue" orphan-queued)"
mv "$orphan_queue" "$TMP/runtime/state/dispatched/Alpha/orphan-queued.json"
MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "orphan queued archive is restored after a late stale move" sh -c \
  'ls "$1"/*orphan-queued* >/dev/null 2>&1' sh "$TMP/runtime/inbox/_queue/Alpha"

# Simulate SIGKILL between archive and delivery commit. An old dispatching record on
# an idle worker is restored to this pod's queue and its exact claim is released.
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-stage" execute --id recover-task context=x task_body=x \
  constraints= output_schema= rollback_plan= scope= >/dev/null
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-queue" recover-task >/dev/null
recover_worker="$(jq -r '.workers[]|select(.status=="idle")|.tmux_window' "$TMP/runtime/state/workers.json" | head -1)"
"$PT" set-option -w -t "$recover_worker" @cc_state idle
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-dispatch" --task recover-task --tmux-window "$recover_worker" >/dev/null
recover_archive="$TMP/runtime/state/dispatched/Alpha/recover-task.json"
jq '.status="dispatching" | .dispatch_started_epoch=1' "$recover_archive" > "$TMP/recover.json"
mv "$TMP/recover.json" "$recover_archive"
"$PT" set-option -w -t "$recover_worker" @cc_state idle
"$PT" set-option -w -t "$recover_worker" @work ""
"$PT" set-option -w -t "$recover_worker" @work_at ""
MGR_DISPATCH_RECOVERY_SECONDS=0 MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" \
  POD_TMP="$TMP/runtime" POD_SESSION=Alpha "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "stale half-dispatch is requeued" sh -c \
  'ls "$1"/*recover-task* >/dev/null 2>&1' sh "$TMP/runtime/inbox/_queue/Alpha"
check "stale half-dispatch releases exact worker" test \
  "$(jq -r --arg w "$recover_worker" '.workers[]|select(.tmux_window==$w)|.status' "$TMP/runtime/state/workers.json")" = idle

# Recovery never races a dispatcher process that is still alive. The claim token
# carries its owner pid; even an ancient phase remains untouched until that owner exits.
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-stage" execute --id live-dispatcher context=x task_body=x \
  constraints= output_schema= rollback_plan= scope= >/dev/null
live_queue="$(POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-queue" live-dispatcher)"
live_token="1-$$-live"
"$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
  claim "$recover_worker" Alpha live-dispatcher old 1 "$live_token"
live_archive="$TMP/runtime/state/dispatched/Alpha/live-dispatcher.json"
mv "$live_queue" "$live_archive"
jq --arg w "$recover_worker" --arg token "$live_token" \
  '. + {status:"dispatching",target:$w,claim_token:$token,dispatch_started_epoch:1}' \
  "$live_archive" > "$TMP/live-dispatcher.json"
mv "$TMP/live-dispatcher.json" "$live_archive"
MGR_DISPATCH_RECOVERY_SECONDS=0 MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" \
  POD_TMP="$TMP/runtime" POD_SESSION=Alpha "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "live dispatcher ownership defers stale recovery" test -f "$live_archive"
check "live dispatcher claim remains assigned" test \
  "$(jq -r --arg w "$recover_worker" '.workers[]|select(.tmux_window==$w)|.status' "$TMP/runtime/state/workers.json")" = busy
"$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
  release "$recover_worker" Alpha live-dispatcher "$live_token"
mv "$live_archive" "$live_queue"

# If a dispatcher dies after touching the live input buffer but before Enter, idle
# is ambiguous: the trigger may still be executable. Fence the live worker instead
# of requeueing, then recover only after the pane (and its stale input) is gone.
uncertain_worker="$("$PT" new-window -d -t Alpha -n uncertain -P -F '#{window_id}' 'sleep 100')"
"$PT" set-option -w -t "$uncertain_worker" @cc_state idle
"$PT" set-option -w -t "$uncertain_worker" @agent_id claude-code
uncertain_entry="$(jq -nc --arg pod Alpha --arg win "$uncertain_worker" \
  '{tmux_session:$pod,tmux_window:$win,agent_id:"claude-code",status:"idle",
    current_task_id:null,registered_at:"now"}')"
"$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
  register "$uncertain_entry"
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-stage" execute --id typed-gap context=x task_body=x \
  constraints= output_schema= rollback_plan= scope= >/dev/null
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-queue" typed-gap >/dev/null
POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-dispatch" --task typed-gap \
    --tmux-window "$uncertain_worker" >/dev/null
uncertain_archive="$TMP/runtime/state/dispatched/Alpha/typed-gap.json"
uncertain_token="$(jq -r '.claim_token' "$uncertain_archive")"
jq '.status="typed" | .dispatch_started_epoch=1' "$uncertain_archive" > "$TMP/typed-gap.json"
mv "$TMP/typed-gap.json" "$uncertain_archive"
"$PT" set-option -w -t "$uncertain_worker" @cc_state idle
"$PT" set-option -w -t "$uncertain_worker" @work ""
"$PT" set-option -w -t "$uncertain_worker" @work_at ""
MGR_DISPATCH_RECOVERY_SECONDS=0 MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" \
  POD_TMP="$TMP/runtime" POD_SESSION=Alpha "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "typed-but-unsubmitted dispatch is fenced, not requeued" test \
  "$(jq -r '.status' "$uncertain_archive")" = delivery_uncertain
check "ambiguous live worker is marked uncertain" test \
  "$(jq -r --arg w "$uncertain_worker" '.workers[]|select(.tmux_window==$w)|.status' "$TMP/runtime/state/workers.json")" = uncertain
if "$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
    check-claim "$uncertain_worker" Alpha typed-gap "$uncertain_token" >/dev/null 2>&1; then
  bad "uncertainty fence stops a paused dispatcher before Enter"
else
  ok "uncertainty fence stops a paused dispatcher before Enter"
fi
check "ambiguous typed task is absent from queue" sh -c \
  '! ls "$1"/*typed-gap* >/dev/null 2>&1' sh "$TMP/runtime/inbox/_queue/Alpha"
# If Enter won the race after the fence, its terminal archive phase restores the
# exact claim to busy so DONE processing cannot strand a delivered task.
jq '.status="dispatched"' "$uncertain_archive" > "$TMP/typed-gap-dispatched.json"
mv "$TMP/typed-gap-dispatched.json" "$uncertain_archive"
MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "submitted dispatch reconciles an uncertainty fence" test \
  "$(jq -r --arg w "$uncertain_worker" '.workers[]|select(.tmux_window==$w)|.status' "$TMP/runtime/state/workers.json")" = busy
check "reconciled delivery makes the exact claim live again" \
  "$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
    check-claim "$uncertain_worker" Alpha typed-gap "$uncertain_token"
"$PT" kill-window -t "$uncertain_worker"
MGR_DISPATCH_RECOVERY_SECONDS=0 MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" \
  POD_TMP="$TMP/runtime" POD_SESSION=Alpha "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "ambiguous task requeues after its pane dies" sh -c \
  'ls "$1"/*typed-gap* >/dev/null 2>&1' sh "$TMP/runtime/inbox/_queue/Alpha"
check "dead ambiguous worker is pruned after recovery" sh -c \
  '! jq -e --arg w "$1" '\''.workers[]|select(.tmux_window==$w)'\'' "$2" >/dev/null' \
  sh "$uncertain_worker" "$TMP/runtime/state/workers.json"

# DONE is authoritative even if the runtime hook never reported busy after an
# uncertain/manual delivery. Completion must release that exact claim.
done_worker="$("$PT" new-window -d -t Alpha -n done-uncertain -P -F '#{window_id}' 'sleep 100')"
"$PT" set-option -w -t "$done_worker" @cc_state idle
done_entry="$(jq -nc --arg pod Alpha --arg win "$done_worker" \
  '{tmux_session:$pod,tmux_window:$win,agent_id:"claude-code",status:"idle",
    current_task_id:null,registered_at:"now"}')"
"$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" register "$done_entry"
"$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
  claim "$done_worker" Alpha done-uncertain old 1 done-token
"$REPO/bin/pod-workers-json" --path "$TMP/runtime/state/workers.json" \
  mark-uncertain "$done_worker" Alpha done-uncertain done-token
mkdir -p "$TMP/runtime/inbox/done-uncertain"
touch "$TMP/runtime/inbox/done-uncertain/DONE"
jq -nc --arg w "$done_worker" \
  '{task_id:"done-uncertain",status:"delivery_uncertain",target:$w,
    claim_token:"done-token",priority:100}' \
  > "$TMP/runtime/state/dispatched/Alpha/done-uncertain.json"
MGR_REAP_FINISHED_WORKERS=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" POD_SESSION=Alpha \
  "$REPO/modules/queue/bin/mgr-poll" >/dev/null
check "DONE releases an uncertain exact claim" test \
  "$(jq -r --arg w "$done_worker" '.workers[]|select(.tmux_window==$w)|.status' "$TMP/runtime/state/workers.json")" = idle
check "DONE clears an uncertain dispatch archive" test \
  ! -e "$TMP/runtime/state/dispatched/Alpha/done-uncertain.json"

# Hook uninstallers remove only exact owned entries and preserve source permissions.
mkdir -p "$TMP/home/.claude" "$TMP/home/.codex"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo pod-mail-check-health"}]}]}}' > "$TMP/home/.claude/settings.json"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo pod-codex-state-health"}]}]}}' > "$TMP/home/.codex/hooks.json"
chmod 600 "$TMP/home/.claude/settings.json" "$TMP/home/.codex/hooks.json"
HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" \
  "$REPO/hooks/claude-code/install.sh" >/dev/null
HOME="$TMP/home" CODEX_HOME="$TMP/home/.codex" \
  "$REPO/hooks/codex/install.sh" >/dev/null
HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/home/.claude" \
  "$REPO/hooks/claude-code/uninstall.sh" >/dev/null
HOME="$TMP/home" CODEX_HOME="$TMP/home/.codex" \
  "$REPO/hooks/codex/uninstall.sh" >/dev/null
check "Claude uninstaller preserves unrelated lookalike" grep -q pod-mail-check-health "$TMP/home/.claude/settings.json"
check "Codex uninstaller preserves unrelated lookalike" grep -q pod-codex-state-health "$TMP/home/.codex/hooks.json"
mode_ok=1
for backup in "$TMP/home/.claude/settings.json".pod-bak.* "$TMP/home/.codex/hooks.json".pod-bak.*; do
  mode="$(stat -f '%Lp' "$backup" 2>/dev/null || stat -c '%a' "$backup")"
  [ "$mode" = 600 ] || { bad "backup mode preserved at 0600 ($backup was $mode)"; mode_ok=0; }
done
[ "$mode_ok" = 1 ] && ok "hook backups preserve 0600 mode"
for config in "$TMP/home/.claude/settings.json" "$TMP/home/.codex/hooks.json"; do
  mode="$(stat -f '%Lp' "$config" 2>/dev/null || stat -c '%a' "$config")"
  check "hook rewrite preserves 0600 mode ($(basename "$config"))" test "$mode" = 600
done

for invocation in \
  'hooks/claude-code/install.sh --settings' \
  'hooks/claude-code/uninstall.sh --settings' \
  'hooks/codex/install.sh --hooks-file' \
  'hooks/codex/uninstall.sh --hooks-file'; do
  set -- $invocation
  if HOME="$TMP/home" "$REPO/$1" "$2" >/dev/null 2>&1; then
    bad "$invocation rejects a missing value"
  else
    ok "$invocation rejects a missing value"
  fi
done

mkdir -p "$TMP/home/.local/bin"
ln -s "$REPO/bin/pod-launch" "$TMP/home/.local/bin/pod-launch"
ln -s "$REPO/bin/_pod-paths.sh" "$TMP/home/.local/bin/_pod-paths.sh"
HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" "$REPO/uninstall.sh" --keep-hooks >/dev/null
check "top-level uninstall removes public command links" test ! -e "$TMP/home/.local/bin/pod-launch"
check "top-level uninstall removes sourced helper links" test ! -e "$TMP/home/.local/bin/_pod-paths.sh"

# Renderer must not pass OSC/ESC payloads from shared chat through to the terminal.
printf '[12:00] Eve → all: x\033]52;c;ZXZpbA==\007y\n' > "$TMP/channel.log"
rendered="$(POD_COLS=80 "$REPO/bin/pod-feed" "$TMP/channel.log" 5)"
if printf '%s' "$rendered" | LC_ALL=C grep -q ']52;'; then
  bad "pod-feed strips terminal control payloads"
else
  ok "pod-feed strips terminal control payloads"
fi

echo "check-safety-invariants: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# check-primer.sh — the operator primer, its user memory, the proactive sandbox
# notice (pod-primer), and the reactive sandbox notice on deck-changing commands
# (pod_require_socket).
#
# Uses the same blocked/live tmux stub as check-sandbox-fallback: MODE=blocked ->
# every tmux call fails (socket EPERM); MODE=live -> answers identity + @is_pod. All
# file-based, no real tmux. bash 3.2 safe.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
note() { echo "check-primer: $*" >&2; }
ok()   { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*"; fails=$((fails + 1)); }
command -v python3 >/dev/null 2>&1 || { note "python3 required"; exit 1; }

STUB="$TMP/bin/tmux"; mkdir -p "$TMP/bin"
cat > "$STUB" <<'EOF'
#!/bin/sh
[ "${STUB_MODE:-blocked}" = "blocked" ] && exit 1
case "${1:-}" in
  display-message)
    case "$*" in
      *"#{window_id}"*)    echo "@9" ;;
      *"#{session_name}"*) echo "testpod" ;;
      *) echo ok ;;
    esac ;;
  show-options) case "$*" in *@is_pod*) echo 1 ;; *) : ;; esac ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$STUB"

PODTMP="$TMP/pod"
mkdir -p "$PODTMP/state"
cat > "$PODTMP/state/tmux_group.json" <<'EOF'
{ "session": "testpod", "pod": "testpod", "manager_window": "@0", "tmux_bin": "tmux", "host": "h" }
EOF

CFG="$TMP/config"; mkdir -p "$CFG"

runenv() {  # $1=mode $2=window ; rest=cmd
  mode="$1"; win="$2"; shift 2
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
    TMUX="/tmp/fake,1,0" TMUX_PANE="%7" POD_TMUX="$STUB" STUB_MODE="$mode" \
    POD_TMP="$PODTMP" POD_CONFIG=/dev/null POD_CONFIG_DIR="$CFG" \
    POD_SESSION=testpod POD_WINDOW="$win" POD_AGENT_ID=claude-code \
    POD_PRIMER="${POD_PRIMER:-1}" \
    "$@"
}
ctx() { python3 -c 'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception: pass'; }

# --- 1. sandboxed manager primer + sandbox notice ---------------------------------
out="$(runenv blocked @0 bash "$REPO/bin/pod-primer" | ctx)"
case "$out" in *"primer (manager)"*) ok "manager role primer emitted" ;; *) bad "no manager primer" ;; esac
case "$out" in *"MANAGER seat"*) ok "manager primer body present" ;; *) bad "manager body missing" ;; esac
case "$out" in *"command sandbox"*) ok "proactive sandbox notice present (manager)" ;; *) bad "no sandbox notice" ;; esac

# --- 2. sandboxed worker primer ---------------------------------------------------
out="$(runenv blocked @2 bash "$REPO/bin/pod-primer" | ctx)"
case "$out" in *"primer (worker)"*) ok "worker role primer emitted for a non-manager window" ;; *) bad "no worker primer" ;; esac
case "$out" in *"MANAGER seat"*) bad "worker got the manager body" ;; *) ok "worker primer is not the manager body" ;; esac

# --- 3. operator memory injected + pod-remember appends ---------------------------
runenv blocked @2 bash "$REPO/bin/pod-remember" "always rebase before pushing" >/dev/null
MEM="$CFG/operator-memory.md"
grep -q 'always rebase before pushing' "$MEM" && ok "pod-remember appended to $MEM" || bad "pod-remember did not write"
grep -qE '^\- \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] ' "$MEM" && ok "pod-remember dated the line" || bad "line not dated"
out="$(runenv blocked @2 bash "$REPO/bin/pod-primer" | ctx)"
case "$out" in *"always rebase before pushing"*) ok "operator memory injected into the primer" ;; *) bad "memory not injected" ;; esac

# --- 4. LIVE socket: primer present, NO sandbox notice ----------------------------
out="$(runenv live @2 bash "$REPO/bin/pod-primer" | ctx)"
case "$out" in *"primer (worker)"*) ok "live: primer still emitted" ;; *) bad "live: no primer" ;; esac
case "$out" in *"command sandbox"*) bad "live: sandbox notice wrongly present" ;; *) ok "live: no sandbox notice (socket works)" ;; esac

# --- 5. POD_PRIMER=0 silences it --------------------------------------------------
out="$(POD_PRIMER=0 runenv blocked @2 bash "$REPO/bin/pod-primer")"
[ -z "$out" ] && ok "POD_PRIMER=0 silences the primer" || bad "POD_PRIMER=0 still emitted"

# --- 6. reactive guard: deck-changing commands warn + fail under a blocked socket -
for pair in "pod-add-worker:spawning a worker" "pod-kill-worker Steve:killing a worker" "pod-auto toggle:toggling FULL AUTO"; do
  cmd="${pair%%:*}"; label="${pair##*:}"
  # shellcheck disable=SC2086
  err="$(runenv blocked @2 bash "$REPO/bin/"$cmd 2>&1 1>/dev/null)"; rc=$?
  case "$err" in
    *"blocked in this command sandbox"*)
      [ "$rc" -ne 0 ] && ok "$cmd: blocked-socket -> notice + non-zero exit" \
                       || bad "$cmd: warned but exited 0" ;;
    *) bad "$cmd: no sandbox notice under a blocked socket (got: $(printf '%s' "$err" | head -1))" ;;
  esac
done

# --- 7. reactive guard is SILENT on the normal path (socket works) ----------------
# (the command may fail later for lack of a real tmux, but NOT with the sandbox notice)
err="$(runenv live @2 bash "$REPO/bin/pod-add-worker" 2>&1 1>/dev/null || true)"
case "$err" in
  *"blocked in this command sandbox"*) bad "pod-add-worker emitted the sandbox notice on a WORKING socket" ;;
  *) ok "pod-add-worker: no sandbox notice when the socket works" ;;
esac

if [ "$fails" -gt 0 ]; then note "$fails failure(s)"; exit 1; fi
note "all checks passed"
exit 0

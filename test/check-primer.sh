#!/usr/bin/env bash
# check-primer.sh — the operator primer and its user memory (pod-primer, pod-remember).
#
# Drives pod-primer against a tmux STUB that answers identity, @is_pod and
# @pod_manager_win, so role gating (manager vs worker) is exercised without a real
# tmux server. All file-based. bash 3.2 safe.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
note() { echo "check-primer: $*" >&2; }
ok()   { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*"; fails=$((fails + 1)); }
command -v python3 >/dev/null 2>&1 || { note "python3 required"; exit 1; }

# $STUB_WIN = the window this pane reports as; $STUB_MGRWIN = the pod's manager window;
# $STUB_ISPOD = the @is_pod stamp (0 lets us assert the non-pod silence).
STUB="$TMP/bin/tmux"; mkdir -p "$TMP/bin"
cat > "$STUB" <<'EOF'
#!/bin/sh
case "${1:-}" in
  display-message)
    case "$*" in
      *"#{window_id}"*)    echo "${STUB_WIN:-@2}" ;;
      *"#{session_name}"*) echo "testpod" ;;
      *) echo ok ;;
    esac ;;
  show-options)
    case "$*" in
      *@is_pod*)          echo "${STUB_ISPOD:-1}" ;;
      *@pod_manager_win*) [ -n "${STUB_MGRWIN:-}" ] && echo "$STUB_MGRWIN" ;;
      *) : ;;
    esac ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$STUB"

PODTMP="$TMP/pod"; mkdir -p "$PODTMP/state"
CFG="$TMP/config"; mkdir -p "$CFG"

runenv() {  # $1=this window ; rest=cmd
  win="$1"; shift
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
    TMUX="/tmp/fake,1,0" TMUX_PANE="%7" POD_TMUX="$STUB" \
    STUB_WIN="$win" STUB_MGRWIN="@0" STUB_ISPOD="${STUB_ISPOD:-1}" \
    POD_TMP="$PODTMP" POD_CONFIG=/dev/null POD_CONFIG_DIR="$CFG" \
    POD_SESSION=testpod \
    POD_PRIMER="${POD_PRIMER:-1}" \
    "$@"
}
ctx() { python3 -c 'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception: pass'; }

# --- 1. manager primer (this window IS the pod's manager window) -------------------
out="$(runenv @0 bash "$REPO/bin/pod-primer" | ctx)"
case "$out" in *"primer (manager)"*) ok "manager role primer emitted" ;; *) bad "no manager primer" ;; esac
case "$out" in *"MANAGER seat"*) ok "manager primer body present" ;; *) bad "manager body missing" ;; esac

# --- 2. worker primer (any other window) -------------------------------------------
out="$(runenv @2 bash "$REPO/bin/pod-primer" | ctx)"
case "$out" in *"primer (worker)"*) ok "worker role primer emitted for a non-manager window" ;; *) bad "no worker primer" ;; esac
case "$out" in *"MANAGER seat"*) bad "worker got the manager body" ;; *) ok "worker primer is not the manager body" ;; esac

# --- 3. operator memory injected + pod-remember appends ---------------------------
runenv @2 bash "$REPO/bin/pod-remember" "always rebase before pushing" >/dev/null
MEM="$CFG/operator-memory.md"
grep -q 'always rebase before pushing' "$MEM" && ok "pod-remember appended to $MEM" || bad "pod-remember did not write"
grep -qE '^\- \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] ' "$MEM" && ok "pod-remember dated the line" || bad "line not dated"
out="$(runenv @2 bash "$REPO/bin/pod-primer" | ctx)"
case "$out" in *"always rebase before pushing"*) ok "operator memory injected into the primer" ;; *) bad "memory not injected" ;; esac

# --- 4. POD_PRIMER=0 silences it --------------------------------------------------
out="$(POD_PRIMER=0 runenv @2 bash "$REPO/bin/pod-primer")"
[ -z "$out" ] && ok "POD_PRIMER=0 silences the primer" || bad "POD_PRIMER=0 still emitted"

# --- 5. an UNSTAMPED session is not a pod: silent ---------------------------------
out="$(STUB_ISPOD=0 runenv @2 bash "$REPO/bin/pod-primer")"
[ -z "$out" ] && ok "silent outside a stamped pod (@is_pod unset)" || bad "emitted in a non-pod session"

if [ "$fails" -gt 0 ]; then note "$fails failure(s)"; exit 1; fi
note "all checks passed"
exit 0

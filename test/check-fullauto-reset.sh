#!/usr/bin/env bash
# check-fullauto-reset.sh — the FULL AUTO fresh-crew reset clears exactly the seats
# it may, and only on the flips it may.
#
# The invariants this guards, in the order a mistake would hurt:
#   1. An AGENT's own `pod-auto on` (an autonomous loop's step 0) NEVER resets —
#      otherwise a manager clears ITSELF the moment it arms its loop.
#   2. A reset types a clear command ONLY into seats whose adapter declares
#      lifecycle.clear_cmd; a plain shell is never typed into, and an agent with no
#      declared command is skipped by name, not guessed at.
#   3. A human flip WITHOUT reset (--yes alone, or --no-reset) types nothing.
#   4. After a reset the manager gets a durable boot brief in its mailbox.
#
# Panes run `cat >> file`, so every byte send-keys delivers is captured verbatim —
# a seat that "received /clear" and a seat that received nothing are both provable.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SOCK="pod-fareset-$$"
TMUX_BIN="$(command -v tmux)"
trap '"$TMUX_BIN" -L "$SOCK" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { echo "  ok: $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $*" >&2; fail=$((fail + 1)); }
check() { desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

[ -n "$TMUX_BIN" ] || { echo "check-fullauto-reset: tmux required" >&2; exit 1; }

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$TMUX_BIN" "$SOCK" > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
PT="$TMP/bin/tmux"

# Pod Alpha: a claude-code manager, a claude-code worker, a plain shell, and a
# foreign agent whose adapter declares no clear_cmd. Every pane appends its input
# to a file so delivered keys are observable.
: > "$TMP/rx-mgr"; : > "$TMP/rx-ada"; : > "$TMP/rx-shelly"; : > "$TMP/rx-cora"
"$PT" new-session -d -s Alpha -n manager "cat >> '$TMP/rx-mgr'"
"$PT" set -t Alpha @is_pod 1
"$PT" set -t Alpha @full_auto 0
AM="$("$PT" display-message -p -t Alpha:0 '#{window_id}')"
"$PT" set -t Alpha @pod_manager_win "$AM"
"$PT" set-option -w -t "$AM" @agent_id claude-code
"$PT" set-option -w -t "$AM" @cc_state idle
W_ADA="$("$PT" new-window -d -t Alpha -n Ada -P -F '#{window_id}' "cat >> '$TMP/rx-ada'")"
"$PT" set-option -w -t "$W_ADA" @agent_id claude-code
W_SHELLY="$("$PT" new-window -d -t Alpha -n Shelly -P -F '#{window_id}' "cat >> '$TMP/rx-shelly'")"
W_CORA="$("$PT" new-window -d -t Alpha -n Cora -P -F '#{window_id}' "cat >> '$TMP/rx-cora'")"
"$PT" set-option -w -t "$W_CORA" @agent_id cursor

auto_state() { "$PT" show-options -t "=Alpha:" -qv @full_auto 2>/dev/null; }
settle() { sleep 0.6; }   # let send-keys bytes reach the cat panes

# --- 1. an agent's own flip never confirms and never resets ---------------------
env -u TMUX -u TMUX_PANE CLAUDECODE=1 POD_AUTO_ANIM=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-auto" on --pod Alpha >/dev/null
settle
check "agent flip turns full-auto on" test "$(auto_state)" = 1
check "agent flip types nothing into the manager" test ! -s "$TMP/rx-mgr"
check "agent flip types nothing into a worker" test ! -s "$TMP/rx-ada"
env -u TMUX -u TMUX_PANE CLAUDECODE=1 POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-auto" off --pod Alpha >/dev/null

# --- 2. an explicit human reset clears exactly the clear_cmd seats --------------
out="$(env -u TMUX -u TMUX_PANE -u CLAUDECODE POD_AUTO_ANIM=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-auto" on --yes --reset --pod Alpha)"
settle
check "reset flip turns full-auto on" test "$(auto_state)" = 1
check "claude-code worker received its clear command" grep -q -- "/clear" "$TMP/rx-ada"
check "manager received its clear command" grep -q -- "/clear" "$TMP/rx-mgr"
check "plain shell received nothing" test ! -s "$TMP/rx-shelly"
check "agent without clear_cmd received nothing" test ! -s "$TMP/rx-cora"
check "skipped seat is reported by name" grep -q "Cora" <<<"$out"
check "manager got the fresh-crew boot brief" grep -q "fresh crew" "$TMP/runtime/comms/Alpha/${AM}.mbox"
env -u TMUX -u TMUX_PANE -u CLAUDECODE POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-auto" off --pod Alpha >/dev/null

# --- 3. a human flip without reset types nothing --------------------------------
: > "$TMP/rx-mgr"; : > "$TMP/rx-ada"
env -u TMUX -u TMUX_PANE -u CLAUDECODE POD_AUTO_ANIM=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-auto" on --yes --pod Alpha >/dev/null
settle
check "plain --yes flip turns full-auto on" test "$(auto_state)" = 1
check "plain --yes flip types nothing" test ! -s "$TMP/rx-mgr"
env -u TMUX -u TMUX_PANE -u CLAUDECODE POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-auto" off --pod Alpha >/dev/null

# --- 4. --no-reset wins over the interactive default ----------------------------
env -u TMUX -u TMUX_PANE -u CLAUDECODE POD_AUTO_ANIM=0 POD_TMUX="$PT" POD_TMP="$TMP/runtime" \
  "$REPO/bin/pod-auto" on --no-reset --pod Alpha >/dev/null
settle
check "--no-reset flip turns full-auto on" test "$(auto_state)" = 1
check "--no-reset flip types nothing" test ! -s "$TMP/rx-ada"

echo "check-fullauto-reset: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

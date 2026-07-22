#!/usr/bin/env bash
# check-context-emit.sh — context injection must NOT hard-require jq.
#
# The regression this guards: every model-facing hook payload (the SessionStart
# roster, the pod journal, podmate deltas, pod-mail delivery) used to be gated on
# `command -v jq || exit 0`. On a machine without jq the deck looked perfectly
# healthy — windows, colors, state dots — while every agent stayed blind to its own
# pod. pod_emit_ctx / pod_json_get (bin/_pod-paths.sh) now fall back jq -> python3
# (a hard dep of hooks/*/install.sh) -> raw stdout, and this test exercises BOTH
# tool paths end-to-end with awkward payloads, plus greps that no emitter has
# reintroduced a bare jq gate. No tmux needed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
note() { echo "check-context-emit: $*" >&2; }
ok()   { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*"; fails=$((fails + 1)); }

command -v python3 >/dev/null 2>&1 || { note "python3 required to run this test"; exit 1; }

# a payload with quotes, newlines, unicode and a backslash — the JSON encoder's job
PAYLOAD='line "one" with <angle> & unicode «pod»
line two\ with a backslash'

# build two minimal PATH sandboxes: one WITH jq (if the host has it), one WITHOUT.
mk_sandbox() {  # $1=dir  $2...=tools to link
  local d="$1"; shift
  mkdir -p "$d"
  local t src
  for t in "$@"; do
    src="$(command -v "$t" 2>/dev/null)" || continue
    ln -s "$src" "$d/$t" 2>/dev/null
  done
}
BASE_TOOLS="bash sh python3 cat printf env dirname readlink uname mktemp"
mk_sandbox "$TMP/nojq" $BASE_TOOLS
mk_sandbox "$TMP/withjq" $BASE_TOOLS jq

validate_emit() {  # $1=label $2=json-ish output
  printf '%s' "$2" | python3 -c '
import json, sys
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "SessionStart", h
expect = """line "one" with <angle> & unicode «pod»
line two\\ with a backslash"""
assert h["additionalContext"] == expect, repr(h["additionalContext"])
' 2>/dev/null && ok "$1: valid JSON, payload survives byte-for-byte" \
    || bad "$1: output failed JSON/payload validation"
}

# --- 1. pod_emit_ctx via the python3 fallback (no jq anywhere on PATH) -------------
out="$(env -i PATH="$TMP/nojq" HOME="$TMP" POD_CONFIG=/dev/null POD_TMP="$TMP/podtmp" \
  PAYLOAD="$PAYLOAD" bash -c ". '$REPO/bin/_pod-paths.sh'; pod_emit_ctx SessionStart \"\$PAYLOAD\"")"
validate_emit "pod_emit_ctx (python3 fallback)" "$out"

# --- 2. pod_emit_ctx via jq (skip silently if the host has no jq) -------------------
if [ -x "$TMP/withjq/jq" ]; then
  out="$(env -i PATH="$TMP/withjq" HOME="$TMP" POD_CONFIG=/dev/null POD_TMP="$TMP/podtmp" \
    PAYLOAD="$PAYLOAD" bash -c ". '$REPO/bin/_pod-paths.sh'; pod_emit_ctx SessionStart \"\$PAYLOAD\"")"
  validate_emit "pod_emit_ctx (jq path)" "$out"
else
  note "host has no jq — jq-path parity check skipped"
fi

# --- 3. raw-stdout last resort (neither jq nor python3) ------------------------------
mk_sandbox "$TMP/bare" bash sh cat printf env dirname readlink uname
out="$(env -i PATH="$TMP/bare" HOME="$TMP" POD_CONFIG=/dev/null POD_TMP="$TMP/podtmp" \
  PAYLOAD="$PAYLOAD" bash -c ". '$REPO/bin/_pod-paths.sh'; pod_emit_ctx SessionStart \"\$PAYLOAD\"")"
[ "$out" = "$PAYLOAD" ] && ok "raw-stdout last resort passes the text through" \
  || bad "raw-stdout last resort mangled the text"

# --- 4. pod_json_get on both PATHs ----------------------------------------------------
printf '{"status": "paused", "pod": "kyoto", "n": 3}\n' > "$TMP/state.json"
for pdir in nojq withjq; do
  [ -d "$TMP/$pdir" ] || continue
  [ "$pdir" = withjq ] && [ ! -x "$TMP/withjq/jq" ] && continue
  got="$(env -i PATH="$TMP/$pdir" HOME="$TMP" POD_CONFIG=/dev/null POD_TMP="$TMP/podtmp" \
    bash -c ". '$REPO/bin/_pod-paths.sh'; pod_json_get '$TMP/state.json' status; echo /; pod_json_get '$TMP/state.json' missing; echo /; pod_json_get '$TMP/nosuch.json' x; echo /")"
  [ "$got" = "paused
/
/
/" ] && ok "pod_json_get ($pdir): value, missing-key, missing-file all correct" \
      || bad "pod_json_get ($pdir): got $(printf '%q' "$got")"
done

# --- 5. no emitter may reintroduce a bare jq gate ---------------------------------------
for f in hooks/claude-code/pod-awareness.sh bin/pod-brief bin/pod-mail-check bin/pod-auto-brief; do
  if grep -n 'command -v jq[^|]*||[[:space:]]*\(exit\|return\)' "$REPO/$f" >/dev/null 2>&1; then
    bad "$f gates on jq again (silent-blind regression) — route through pod_emit_ctx/pod_json_get"
  else
    ok "$f has no bare jq gate"
  fi
done

if [ "$fails" -gt 0 ]; then note "$fails failure(s)"; exit 1; fi
note "all checks passed"
exit 0

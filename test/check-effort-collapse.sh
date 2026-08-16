#!/usr/bin/env bash
# check-effort-collapse.sh — baked-effort vendor ids collapse into model families
# with a real effort ladder, without ever minting an id discovery didn't return.
#
# The regression class this guards, both directions:
#   - WITHOUT the collapse, a Cursor-style CLI (effort baked into the model id)
#     floods the picker with near-duplicate ids and exposes no effort axis at all.
#   - A WRONG collapse is worse: "-extra-high" mis-split as base "…-extra" + rung
#     "high" launches a model id the vendor never listed, and a static ladder that
#     overrode a discovered one could assert rungs discovery never proved.
#
# Uses a fake adapter whose discovery is a printf, so every expectation is exact.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { echo "  ok: $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $*" >&2; fail=$((fail + 1)); }
check() { desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "check-effort-collapse: python3 required" >&2; exit 1; }

mkdir -p "$TMP/adapters" "$TMP/user-adapters" "$TMP/runtime"
cat > "$TMP/adapters/fakefx.toml" <<'TOML'
[agent]
id       = "fakefx"
label    = "Fake FX"
priority = 40

[launch]
base_cmd   = "fakefx-agent"
model_arg  = ["--model", "{model}"]
effort_arg = []

[detect]
pane_cmd_patterns = ['^fakefx-agent$']

[lifecycle]
mode = "poll"

[discover]
models_cmd   = "printf 'auto - Auto (current)\ngrok-4.6-xhigh - Grok 4.6 XHigh\ngrok-4.6-low - Grok 4.6 Low\ngpt-9-extra-high - GPT 9 Extra High\nsolo-2 - Solo Two\nbase-x - Base X\nbase-x-high - Base X High\n'"
models_regex = '^(\S+)\s+-\s+(.+?)(?:\s+\(current\))?$'
timeout_s    = 6
ttl_s        = 300
efforts      = []
effort_suffixes = ["max", "xhigh", "extra-high", "high", "medium", "low", "none"]
TOML

pa() {
  POD_ADAPTERS_DIR="$TMP/adapters" POD_USER_ADAPTERS="$TMP/user-adapters" \
    POD_STATE="$TMP/runtime/state" "$REPO/bin/pod-adapter" "$@"
}

models="$(pa models fakefx)"
check "unsuffixed ids pass through" grep -q '^auto	' <<<"$models"
check "suffixed ids collapse to one family" grep -q '^grok-4.6	' <<<"$models"
if grep -q 'grok-4.6-xhigh' <<<"$models"; then
  bad "baked rungs vanish from the model list"
else
  ok "baked rungs vanish from the model list"
fi
check "longest suffix wins the split" grep -q '^gpt-9	' <<<"$models"
if grep -q 'gpt-9-extra' <<<"$models"; then
  bad "extra-high is never mis-split as …-extra + high"
else
  ok "extra-high is never mis-split as …-extra + high"
fi
check "a bare family keeps its discovered label" grep -q '^base-x	Base X$' <<<"$models"

grok_efforts="$(pa efforts fakefx grok-4.6)"
check "family ladder holds exactly the proven rungs" test "$(printf '%s\n' "$grok_efforts" | awk -F'\t' '{print $1}' | tr '\n' ' ')" = "xhigh low "
basex_efforts="$(pa efforts fakefx base-x)"
check "a discovered bare id becomes the leading default rung" test "$(printf '%s\n' "$basex_efforts" | head -1 | awk -F'\t' '{print $1}')" = default

check "rung launch substitutes the full baked id" test \
  "$(pa launch fakefx --model grok-4.6 --effort xhigh)" = "fakefx-agent --model grok-4.6-xhigh"
check "extra-high rung launches its exact vendor id" test \
  "$(pa launch fakefx --model gpt-9 --effort extra-high)" = "fakefx-agent --model gpt-9-extra-high"
check "default rung launches the bare id" test \
  "$(pa launch fakefx --model base-x --effort default)" = "fakefx-agent --model base-x"
check "model-only launch of a bare family uses the bare id" test \
  "$(pa launch fakefx --model base-x)" = "fakefx-agent --model base-x"
check "model-only launch of a rung-only family names a real id" test \
  "$(pa launch fakefx --model grok-4.6)" = "fakefx-agent --model grok-4.6-xhigh"
if pa launch fakefx --model grok-4.6 --effort medium >/dev/null 2>&1; then
  bad "an unproven rung is rejected at launch"
else
  ok "an unproven rung is rejected at launch"
fi
check "passthrough id still launches verbatim" test \
  "$(pa launch fakefx --model auto)" = "fakefx-agent --model auto"

echo "check-effort-collapse: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

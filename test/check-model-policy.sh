#!/usr/bin/env bash
# check-model-policy.sh — the provider-backend model policy for claude-code.
#
# Behind Bedrock/Vertex/a gateway, first-party model IDs 400 — so pod-adapter must
# (1) skip --model entirely when a provider env var is set (seat inherits the
#     environment's model), while still passing --effort through,
# (2) honor POD_CLAUDE_MODEL as a verbatim pin that bypasses the catalog,
# (3) leave first-party setups and non-claude agents byte-identical to before.
# Exercised through `launch`, `card`, and `resolve-model` with a scrubbed env so a
# developer's real Bedrock/pin config can't leak into the assertions. No tmux needed.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTER="$REPO/bin/pod-adapter"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
note() { echo "check-model-policy: $*" >&2; }

# every invocation runs with provider + pin vars scrubbed, discovery cache isolated,
# and no API key (so the claude-code [discover] block falls back to the static list).
run() {
  env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY \
      -u POD_CLAUDE_MODEL -u ANTHROPIC_API_KEY POD_TMP="$TMP" "$@"
}

expect() {  # <desc> <needle> <<< haystack ; needle="" asserts --model absent
  desc="$1"; needle="$2"; got="$(cat)"
  if [ -z "$needle" ]; then
    case "$got" in *--model*) note "FAIL: $desc — expected no --model, got: $got"; fails=$((fails+1)) ;; esac
  else
    case "$got" in *"$needle"*) : ;; *) note "FAIL: $desc — expected '$needle' in: $got"; fails=$((fails+1)) ;; esac
  fi
}

# 1. first-party (no provider env): today's behavior, catalog slug resolves
run "$ADAPTER" launch claude-code --model opus --effort high \
  | expect "first-party launch keeps catalog ID" "--model claude-opus-4-8"

# 2. provider backend: --model dropped, --effort survives
run env CLAUDE_CODE_USE_BEDROCK=1 "$ADAPTER" launch claude-code --model opus --effort high \
  | expect "bedrock launch drops --model" ""
run env CLAUDE_CODE_USE_BEDROCK=1 "$ADAPTER" launch claude-code --model opus --effort high \
  | expect "bedrock launch keeps --effort" "--effort high"

# 3. pin: POD_CLAUDE_MODEL passes verbatim (provider ID format, not in the catalog)
run env CLAUDE_CODE_USE_BEDROCK=1 POD_CLAUDE_MODEL="us.anthropic.claude-opus-4-8-v1:0" \
    "$ADAPTER" launch claude-code --model opus \
  | expect "pin overrides catalog verbatim" "--model us.anthropic.claude-opus-4-8-v1:0"

# 4. resolve-model: inherit prints empty, pin prints the pin, plain passes through
r="$(run env CLAUDE_CODE_USE_BEDROCK=1 "$ADAPTER" resolve-model claude-code opus)"
[ -z "$r" ] || { note "FAIL: resolve-model under bedrock should be empty, got '$r'"; fails=$((fails+1)); }
r="$(run env POD_CLAUDE_MODEL=my-gateway-model "$ADAPTER" resolve-model claude-code opus)"
[ "$r" = "my-gateway-model" ] || { note "FAIL: resolve-model pin, got '$r'"; fails=$((fails+1)); }
r="$(run "$ADAPTER" resolve-model claude-code opus)"
[ "$r" = "opus" ] || { note "FAIL: resolve-model passthrough, got '$r'"; fails=$((fails+1)); }

# 5. other agents are untouched by the claude policy
r="$(run env CLAUDE_CODE_USE_BEDROCK=1 "$ADAPTER" resolve-model codex gpt-5.5)"
[ "$r" = "gpt-5.5" ] || { note "FAIL: non-claude agent passthrough, got '$r'"; fails=$((fails+1)); }

# 6. card mirrors the launch decision: no stale first-party label under inherit
run env CLAUDE_CODE_USE_BEDROCK=1 "$ADAPTER" card claude-code --model opus --effort high \
  | expect "bedrock card omits first-party model label" "Claude Code · high"
run env POD_CLAUDE_MODEL=my-gateway-model "$ADAPTER" card claude-code --model opus \
  | expect "pinned card shows the pin" "my-gateway-model"

if [ "$fails" -gt 0 ]; then note "$fails failure(s)"; exit 1; fi
note "ok — provider-backend model policy holds"

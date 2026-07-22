#!/usr/bin/env bash
# Local model discovery is authoritative; hardcoded/static rows never assert access.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADAPTER="$REPO/bin/pod-adapter"
DISCOVER="$REPO/bin/pod-discover-local-agent"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-pods-model-policy.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/adapters" "$TMP/state"

cat > "$TMP/claude-screen.txt" <<'EOF'
   Select model
   Switch between Claude models.

   ❯ 1. Default (recommended) ✔  Acme Prime · Company default
     2. AcmePrime               Acme Prime · Best for complex work
     3. AcmeFast                Acme Fast · Low-latency company model
EOF

cat > "$TMP/codex-screen.txt" <<'EOF'
  Select Model and Effort
  Access legacy models by running codex -m <model_name>

› 1. corp-codex-pro (current)  Company coding model.
  2. corp-codex-fast           Fast company coding model.

  Press enter to confirm or esc to go back
EOF

claude_rows="$($DISCOVER claude-code --screen "$TMP/claude-screen.txt")"
grep -qx $'default\tDefault (Acme Prime)\t' <<<"$claude_rows"
grep -qx $'acmeprime\tAcme Prime\tAcmePrime' <<<"$claude_rows"
grep -qx $'acmefast\tAcme Fast\tAcmeFast' <<<"$claude_rows"

codex_rows="$($DISCOVER codex --screen "$TMP/codex-screen.txt")"
grep -qx $'corp-codex-pro\tcorp-codex-pro\tcorp-codex-pro' <<<"$codex_rows"
grep -qx $'corp-codex-fast\tcorp-codex-fast\tcorp-codex-fast' <<<"$codex_rows"

cat > "$TMP/adapters/corporate.toml" <<EOF
[agent]
id = "corporate"
label = "Corporate Agent"

[launch]
base_cmd = "agent"
model_arg = ["--model", "{model}"]
effort_arg = ["--effort", "{effort}"]

[defaults]
model = "inherit"
effort = ""

[lifecycle]
mode = "poll"
installer = ""
native_delivery = false
state_source = "poll"

[discover]
models_cmd = "$DISCOVER claude-code --screen $TMP/claude-screen.txt"
models_format = "tsv"
timeout_s = 2
ttl_s = 300
efforts = [ { slug = "high", label = "high", value = "high" } ]

# Annotation for a model discovery did not return. It must never become selectable.
[[models]]
slug = "ghost"
label = "Hardcoded Ghost"
model = "ghost-model"
efforts = []
EOF

run_adapter() {
  POD_ADAPTERS_DIR="$TMP/adapters" POD_USER_ADAPTERS="$TMP/missing" \
    POD_STATE="$TMP/state" "$ADAPTER" "$@"
}

models="$(run_adapter models corporate)"
grep -qx $'inherit\tAgent default (inherited)' <<<"$models"
grep -qx $'acmeprime\tAcme Prime' <<<"$models"
if grep -q 'ghost\|Hardcoded Ghost' <<<"$models"; then
  echo "static model incorrectly asserted as available" >&2
  exit 1
fi

[ "$(run_adapter launch corporate --model inherit)" = "agent" ]
[ "$(run_adapter launch corporate --model inherit --effort high)" = "agent --effort high" ]
[ "$(run_adapter launch corporate --model acmeprime)" = "agent --model AcmePrime" ]
[ "$(run_adapter resolve-model corporate ghost)" = "inherit" ]
[ "$(run_adapter resolve-effort corporate inherit high)" = "high" ]
[ -z "$(run_adapter resolve-effort corporate inherit ghost)" ]
[ "$(run_adapter card corporate --model inherit)" = "Corporate Agent · Agent default (inherited)" ]
[ "$(run_adapter card corporate --model inherit --effort high)" = "Corporate Agent · Agent default (inherited) · high" ]

# A malformed but valid-JSON cache must be ignored and refreshed, not crash the
# picker or become launch metadata.
printf '%s\n' '{"models":[1]}' > "$TMP/state/discover/corporate.json"
grep -qx $'acmeprime\tAcme Prime' <<<"$(run_adapter models corporate)"

# Persisted quick-pick metadata is only a preference. Both the menu label and the
# click command must resolve a removed model through today's local catalog.
printf '%s\n' '{"slots":[{"label":"Corporate Agent · Hardcoded Ghost","agent":"corporate","model":"ghost","effort":"high","cmd":"agent --model ghost-model"}]}' > "$TMP/slots.json"
menu="$(POD_MENU_PRINT=1 POD_SLOTS="$TMP/slots.json" POD_ADAPTERS_DIR="$TMP/adapters" \
  POD_USER_ADAPTERS="$TMP/missing" POD_STATE="$TMP/state" \
  "$REPO/bin/pod-spawn-menu-build")"
grep -q 'Corporate Agent · Agent default (inherited) · high' <<<"$menu"
if grep -q 'Hardcoded Ghost\|ghost-model\|--label' <<<"$menu"; then
  echo "quick picker leaked stale model metadata" >&2
  exit 1
fi

# Agent ids become cache keys and shell-menu arguments, so unsafe ids are rejected at
# the adapter boundary.
cat > "$TMP/adapters/unsafe.toml" <<'EOF'
[agent]
id = "../../escape"
label = "Unsafe"
[launch]
base_cmd = "agent"
model_arg = ["--model", "{model}"]
EOF
if run_adapter list 2>/dev/null | grep -q escape; then
  echo "unsafe adapter id was loaded" >&2
  exit 1
fi

# Bundled adapters must not ship authoritative model rows.
if rg -n '^\[\[models\]\]' "$REPO/adapters" --glob '!_schema.toml'; then
  echo "bundled adapter contains a hardcoded model catalog" >&2
  exit 1
fi

echo "check-model-policy: local discovery is authoritative"

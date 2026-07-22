#!/usr/bin/env bash
# A timed-out shell discovery must not leave a child holding the capture pipe open.
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pod-adapter-timeout.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/adapters" "$TMP/state"

cat > "$TMP/slow-discovery" <<'SH'
#!/usr/bin/env sh
sleep 30
SH
chmod +x "$TMP/slow-discovery"

cat > "$TMP/adapters/slow.toml" <<EOF
[agent]
id = "slow"
label = "Slow"

[launch]
base_cmd = "sh"
model_arg = ["--model", "{model}"]
effort_arg = []

[discover]
models_cmd = "$TMP/slow-discovery"
timeout_s = 0.2

EOF

SECONDS=0
output="$(POD_ADAPTERS_DIR="$TMP/adapters" POD_USER_ADAPTERS="$TMP/missing" \
  POD_STATE="$TMP/state" "$REPO/bin/pod-adapter" models slow)"
elapsed="$SECONDS"

[ "$output" = $'inherit\tAgent default (inherited)' ] || {
  echo "unexpected fallback output: $output" >&2
  exit 1
}
[ "$elapsed" -lt 3 ] || {
  echo "discovery timeout took ${elapsed}s; child likely retained the capture pipe" >&2
  exit 1
}

echo "ok: discovery process group terminated in ${elapsed}s"

#!/usr/bin/env bash
# A shared settings.json may intentionally contain hooks from two live checkouts.
# Reinstalling one checkout must preserve the other; only a hook whose target has
# actually disappeared is stale and eligible for pruning.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SETTINGS="$TMP/settings.json"
OTHER="$TMP/other/bin"
mkdir -p "$OTHER"
printf '#!/bin/sh\n' > "$OTHER/pod-state"
chmod +x "$OTHER/pod-state"

python3 - "$SETTINGS" "$OTHER/pod-state" <<'PY'
import json, sys
path, other = sys.argv[1:]
json.dump({"hooks":{"Stop":[{"hooks":[{
    "type":"command", "command":'bash "%s" idle' % other, "timeout":3
}]}]}}, open(path, "w"))
PY

"$REPO/hooks/claude-code/install.sh" --settings "$SETTINGS" >/dev/null
python3 - "$SETTINGS" "$OTHER/pod-state" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h.get("command", "") for g in d["hooks"]["Stop"] for h in g.get("hooks", [])]
assert any(sys.argv[2] in c for c in cmds), cmds
assert any("/agent-pods/bin/pod-state" in c or c.endswith('/bin/pod-state" idle') for c in cmds), cmds
PY
echo "  ok: live second-checkout hook is preserved"

rm -f "$OTHER/pod-state"
"$REPO/hooks/claude-code/install.sh" --settings "$SETTINGS" >/dev/null
python3 - "$SETTINGS" "$OTHER/pod-state" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h.get("command", "") for groups in d.get("hooks", {}).values()
        for g in groups for h in g.get("hooks", [])]
assert not any(sys.argv[2] in c for c in cmds), cmds
PY
echo "  ok: missing second-checkout hook is pruned"
echo "check-hook-ownership: all checks passed"

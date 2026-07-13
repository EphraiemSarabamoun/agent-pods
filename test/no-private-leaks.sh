#!/usr/bin/env bash
# no-private-leaks.sh — CI guard: the public tree must carry NO private identifiers.
# agent-pods is the open-source extraction of a private deck; this fails the build if a
# future port ever drags in a name/path/persona from the original. bash 3.2 safe.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 2

# Identifiers that must never appear in the public tree. Bare "claude" is legitimate
# (the claude-code adapter); these are the SPECIFIC private terms.
PAT='claudius|claude-fleet|claude-configs|/Users/fatherdomadious|manager-inbox|CLAUDIUS_POD|/opt/homebrew/bin/tmux|\bEphraiem\b|\bcaesar\b|\bloki\b|\bnapoleon\b|\bpixie\b'

# Scan the shipped sources; skip .git and THIS file (it necessarily contains the words).
# The LICENSE copyright line carries the author's real name BY DESIGN (standard MIT
# attribution) — that one line is allowed; any other Ephraiem/path/host hit still fails.
hits="$(grep -rIinE "$PAT" \
  bin modules adapters hooks docs config test \
  install.sh uninstall.sh README.md LICENSE CHANGELOG.md .gitignore 2>/dev/null \
  | grep -v '^test/no-private-leaks.sh:' \
  | grep -vE '^LICENSE:[0-9]+:Copyright \(c\)')"

if [ -n "$hits" ]; then
  echo "no-private-leaks.sh: FAIL — private identifiers found in the public tree:" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "no-private-leaks.sh: ok — no private identifiers in the tree."

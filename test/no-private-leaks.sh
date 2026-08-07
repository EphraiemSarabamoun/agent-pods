#!/usr/bin/env bash
# no-private-leaks.sh — CI guard: the public tree must carry no private identifiers.
#
# agent-pods is an open-source extraction of a private deck. This fails the build if a
# future port ever drags a name, path, host or persona out of the original tree.
#
# The patterns themselves are NOT stored here. A denylist is a map of exactly what you
# are trying to hide: shipping the terms in a public repo publishes the inventory the
# guard exists to protect. So the terms live OUTSIDE the repo and this script only
# carries the mechanism.
#
#   patterns file   $POD_PRIVATE_PATTERNS, else ${XDG_CONFIG_HOME:-~/.config}/pod/private-patterns.txt
#   format          one extended-regex (grep -E) pattern per line; # comments and
#                   blank lines ignored; leading/trailing whitespace stripped
#   no file         SKIP, exit 0 — a fork or an outside contributor has no private
#                   identifiers of ours to leak, so there is nothing to check
#   --require       fail instead of skipping when no patterns are configured; use this
#                   in the pre-publish run, where a silent skip is the dangerous case
#
# bash 3.2 safe.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 2

REQUIRE=0
for arg in "$@"; do
  case "$arg" in
    --require) REQUIRE=1 ;;
    -h|--help)
      echo "usage: no-private-leaks.sh [--require]"
      echo "  Scans the tree for the patterns in \$POD_PRIVATE_PATTERNS"
      echo "  (default \${XDG_CONFIG_HOME:-~/.config}/pod/private-patterns.txt)."
      echo "  --require: fail if no patterns file is configured (pre-publish)."
      exit 0 ;;
    *) echo "no-private-leaks.sh: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

PATFILE="${POD_PRIVATE_PATTERNS:-${XDG_CONFIG_HOME:-$HOME/.config}/pod/private-patterns.txt}"

if [ ! -f "$PATFILE" ]; then
  if [ "$REQUIRE" -eq 1 ]; then
    echo "no-private-leaks.sh: FAIL — --require given but no patterns file at $PATFILE" >&2
    echo "  Write one pattern per line there (or point \$POD_PRIVATE_PATTERNS at it) and re-run." >&2
    exit 1
  fi
  echo "no-private-leaks.sh: skipped — no patterns file at $PATFILE (nothing to check)."
  exit 0
fi

# Build one alternation from the file. Read with `read -r` so backslashes in a regex
# survive; strip comments and surrounding whitespace.
PAT=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  # trim leading/trailing whitespace without bash 4 features
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$line" ] || continue
  if [ -z "$PAT" ]; then PAT="$line"; else PAT="$PAT|$line"; fi
done < "$PATFILE"

if [ -z "$PAT" ]; then
  if [ "$REQUIRE" -eq 1 ]; then
    echo "no-private-leaks.sh: FAIL — $PATFILE has no usable patterns (all blank/comments)." >&2
    exit 1
  fi
  echo "no-private-leaks.sh: skipped — $PATFILE has no usable patterns."
  exit 0
fi

# Scan the shipped sources. Two exemptions:
#   - this file, so a pattern that happens to match the mechanism cannot self-trip
#   - the LICENSE copyright line, which carries the author's real name by design
#     (standard MIT attribution). Any OTHER hit in LICENSE still fails.
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
echo "no-private-leaks.sh: ok — no private identifiers in the tree ($(grep -cvE '^[[:space:]]*(#|$)' "$PATFILE") pattern(s) checked)."

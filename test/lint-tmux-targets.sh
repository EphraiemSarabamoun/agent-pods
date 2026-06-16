#!/usr/bin/env bash
# lint-tmux-targets.sh — guard against the tmux fuzzy-prefix-match footgun.
#
# THE GOTCHA: tmux target matching is FUZZY. `tmux has-session -t pod` returns true for a
# session named `pod-7`, because `pod` is a prefix of `pod-7`. The same applies to
# `kill-session -t pod` (which could kill the WRONG session) and to session-existence
# `list-windows` probes. The fix, used by every keystone in bin/, is a leading `=` on the
# target (`-t "=$S"`, `-t =$S`, `-t "=$s"`) which forces an EXACT-name match.
#
# This linter greps bin/ and modules/ for has-session / kill-session / list-windows calls
# and flags any whose target risks a fuzzy prefix match:
#   - has-session / kill-session: these are SESSION-scoped and a fuzzy match is ALWAYS a
#     bug, so the target MUST be `=`-prefixed (literal `=name` or `=$var`). Any non-`=`
#     target (bareword OR variable) is flagged.
#   - list-windows: a `-t "$var"` is the legitimate window-ENUMERATION case (list the
#     windows of a session you already hold), so a variable target is fine; but a bare
#     LITERAL session name without `=` (e.g. `-t pod`) is a fuzzy-prefix risk and IS
#     flagged.
# Comment lines (the explanatory NOTE in pod-launch quotes `has-session -t pod` in prose)
# are skipped.
#
# Exits 0 only if nothing is flagged; non-zero on any finding. It PASSES against the
# current bin/ (the keystones already use `=`). A small ALLOWLIST below excuses known-safe
# lines by "file:line" if a future legitimate exception ever needs it.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIRS=""
[ -d "$REPO/bin" ]     && DIRS="$DIRS $REPO/bin"
[ -d "$REPO/modules" ] && DIRS="$DIRS $REPO/modules"
[ -n "$DIRS" ] || { echo "lint-tmux-targets.sh: no bin/ or modules/ to lint" >&2; exit 2; }

# Known-safe "file:line" entries (relative to the repo root). Empty by default — the
# current tree needs no exceptions; this exists so a future legit case has an escape hatch.
ALLOWLIST="
"

is_allowlisted() {
  case "$ALLOWLIST" in
    *"
$1
"*) return 0 ;;
  esac
  return 1
}

findings=0

# Scan every file under the linted dirs. We read line-by-line so we can see context
# (skip comments) and report file:line. bash 3.2 safe: no mapfile, no associative arrays.
for d in $DIRS; do
  # plain find over regular files; portable, no -print0 needed since paths here are tame.
  for file in $(find "$d" -type f 2>/dev/null); do
    rel="${file#$REPO/}"
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))

      # only lines that invoke one of the three session-target commands
      case "$line" in
        *has-session*|*kill-session*|*list-windows*) : ;;
        *) continue ;;
      esac

      # strip a leading-whitespace comment line (prose like the pod-launch NOTE)
      trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
      case "$trimmed" in \#*) continue ;; esac

      loc="$rel:$lineno"
      is_allowlisted "$loc" && continue

      # Extract the token immediately following `-t`. We accept the common quotings:
      #   -t "=$S"   -t =$S   -t "=name"   -t =name        (SAFE: = prefix)
      #   -t "$S"    -t $S                                  (var: safe ONLY for list-windows)
      #   -t pod     -t "pod"                               (bare literal: risk)
      # Pull just the target word (up to the next space or quote) for classification.
      tgt="$(printf '%s' "$line" | sed -n 's/.*-t[[:space:]]\{1,\}\(["'"'"']\{0,1\}[^[:space:]"'"'"']*\).*/\1/p')"
      [ -n "$tgt" ] || continue

      # normalize: drop a single leading quote so `"=$S` and `=$S` classify the same.
      bare="${tgt#\"}"; bare="${bare#\'}"

      # SAFE if the (post-quote) target begins with `=` (exact-match forced).
      case "$bare" in =*) continue ;; esac

      # Determine which command this line uses (the nearest of the three before -t).
      cmd=""
      case "$line" in
        *has-session*)  cmd="has-session" ;;
        *kill-session*) cmd="kill-session" ;;
        *list-windows*) cmd="list-windows" ;;
      esac

      if [ "$cmd" = "list-windows" ]; then
        # variable target (`$S`, `"$sess"`) is the legit enumeration case -> allow.
        case "$bare" in \$*) continue ;; esac
        # otherwise a bare LITERAL session name without `=` -> flag.
      fi
      # has-session / kill-session: any non-`=` target (bareword OR var) is flagged.

      printf 'FAIL  %s  (%s target without leading "="): %s\n' \
        "$loc" "$cmd" "$trimmed" >&2
      findings=$((findings + 1))
    done < "$file"
  done
done

if [ "$findings" -gt 0 ]; then
  printf '\nlint-tmux-targets.sh: %d fuzzy-prefix-match risk(s) found.\n' "$findings" >&2
  printf 'Fix by prefixing the target with "=" to force an exact-name match (e.g. -t "=$S").\n' >&2
  exit 1
fi

echo "lint-tmux-targets.sh: ok — no fuzzy-prefix-match risks."

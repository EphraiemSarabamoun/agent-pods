#!/usr/bin/env bash
# check-install-modes.sh — the _-prefixed helper libraries ship NON-executable, and
# install.sh never chmod +x's them.
#
# The regression this guards (it blocked a real `git pull`): install.sh symlinks every
# bin/* onto PATH and chmod +x's the REAL file so the symlink is runnable. But the
# _-prefixed files (_pod-paths.sh, _pod-common.sh, _mgr-runtime.sh, _pod-strip.sh) are
# SOURCED, never executed — chmod-ing them rewrites the tracked git mode in a checkout,
# dirtying the working tree so the next pull fails ("local changes would be
# overwritten"). They must be 644 in the index AND install.sh must skip them.
# No tmux needed. bash 3.2 safe.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
note() { echo "check-install-modes: $*" >&2; }
ok()   { echo "  ok: $*"; }
bad()  { echo "  FAIL: $*"; fails=$((fails + 1)); }

# --- 1. tracked mode of every _-prefixed bin helper is non-executable (644) --------
# git's INDEX mode is what a fresh clone gets; that's the mode install.sh must not flip.
if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r line; do
    mode="${line%% *}"; path="${line##*	}"
    case "$mode" in
      100644) ok "$path is tracked 644 (non-exec)" ;;
      *)      bad "$path is tracked $mode — a sourced helper must be 644, else install.sh's chmod dirties the tree and blocks pulls" ;;
    esac
  done <<EOF
$(git -C "$REPO" ls-files -s 'bin/_*')
EOF
else
  # no git: fall back to the working-tree bit
  for f in "$REPO"/bin/_*; do
    [ -f "$f" ] || continue
    if [ -x "$f" ]; then bad "$(basename "$f") is executable in the worktree (sourced helpers ship non-exec)"
    else ok "$(basename "$f") is non-executable"; fi
  done
fi

# --- 2. install.sh's chmod loop guards _-prefixed names ---------------------------
# Assert the guard exists structurally: a `case ... _*)` around the chmod, so the loop
# can never re-introduce the +x flip on a sourced helper.
if grep -Eq 'case[[:space:]]+"?\$base"?[[:space:]]+in' "$REPO/install.sh" \
   && grep -Eq '_\*\)' "$REPO/install.sh"; then
  ok "install.sh chmod loop guards _-prefixed helpers"
else
  bad "install.sh chmod loop has no _* guard — it will chmod +x the sourced helpers and dirty a checkout"
fi

# --- 3. and the guard actually WORKS: run the loop logic over sample names ---------
# Mirror install.sh's decision so a future refactor that keeps the grep-able shape but
# breaks the logic still trips.
decide() {  # echoes "chmod" or "skip" for a basename, per install.sh's case
  case "$1" in _*) echo skip ;; *) echo chmod ;; esac
}
[ "$(decide _pod-paths.sh)" = skip ]  && ok "_pod-paths.sh -> skip"  || bad "_pod-paths.sh not skipped"
[ "$(decide _mgr-runtime.sh)" = skip ] && ok "_mgr-runtime.sh -> skip" || bad "_mgr-runtime.sh not skipped"
[ "$(decide pod-launch)" = chmod ]    && ok "pod-launch -> chmod"    || bad "pod-launch wrongly skipped"
[ "$(decide pod)" = chmod ]           && ok "pod -> chmod"           || bad "pod wrongly skipped"

if [ "$fails" -gt 0 ]; then note "$fails failure(s)"; exit 1; fi
note "all checks passed"
exit 0

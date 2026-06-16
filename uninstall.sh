#!/usr/bin/env bash
# uninstall.sh — undo what install.sh did, conservatively.
#
# Removes the bin/* symlinks this repo placed in ~/.local/bin (only links that actually
# point back into THIS repo's bin/ are touched — a same-named link to something else is
# left alone). Offers to remove the Claude Code lifecycle hooks. Your config in
# ~/.config/pod (slots.json, config.sh) is LEFT INTACT unless you pass --purge.
#
#   ./uninstall.sh                 remove symlinks, offer to remove Claude Code hooks
#   ./uninstall.sh --remove-hooks  non-interactively remove the Claude Code hooks
#   ./uninstall.sh --keep-hooks    non-interactively leave the Claude Code hooks
#   ./uninstall.sh --purge         also delete ~/.config/pod (your slots + config)
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
POD_BIN="$REPO/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pod"
LOCAL_BIN="$HOME/.local/bin"
CLAUDE_HOOKS_UNINSTALLER="$REPO/hooks/claude-code/uninstall.sh"

HOOKS_CHOICE="ask"
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --remove-hooks) HOOKS_CHOICE="yes" ;;
    --keep-hooks)   HOOKS_CHOICE="no" ;;
    --purge)        PURGE=1 ;;
    -h|--help)
      echo "usage: uninstall.sh [--remove-hooks | --keep-hooks] [--purge]"
      echo "  Removes agent-pods bin symlinks; --purge also deletes ~/.config/pod."
      exit 0 ;;
    *) echo "uninstall.sh: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*" >&2; }

# --- remove symlinks that point into this repo's bin/ ----------------------------
say "Removing command symlinks from $LOCAL_BIN"
removed=0
if [ -d "$LOCAL_BIN" ]; then
  # Walk the repo's bin/ for the names we WOULD have linked (same filter as install.sh:
  # user-facing commands, not the sourced _pod-* helpers), and remove a link only when
  # it actually resolves back into THIS repo's bin — never a same-named foreign link.
  for f in "$POD_BIN"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in _*) continue ;; esac
    link="$LOCAL_BIN/$base"
    [ -L "$link" ] || continue
    target="$(readlink "$link" 2>/dev/null || true)"
    # resolve relative targets against the link's own directory before comparing
    case "$target" in
      /*) resolved="$target" ;;
      *)  resolved="$LOCAL_BIN/$target" ;;
    esac
    if [ "$target" = "$f" ] || [ "$resolved" = "$f" ]; then
      rm -f "$link" && removed=$((removed + 1))
    fi
  done
fi
ok "removed $removed symlink(s)"

# --- offer to remove Claude Code hooks -------------------------------------------
say ""
say "Claude Code lifecycle hooks"
if [ ! -x "$CLAUDE_HOOKS_UNINSTALLER" ]; then
  ok "no hook uninstaller at $CLAUDE_HOOKS_UNINSTALLER — skipping."
else
  do_hooks="no"
  case "$HOOKS_CHOICE" in
    yes) do_hooks="yes" ;;
    no)  do_hooks="no"; ok "leaving Claude Code hooks in place (--keep-hooks)" ;;
    ask)
      if [ -t 0 ]; then
        printf '  Remove the agent-pods Claude Code hooks from your settings.json? [y/N] '
        read -r reply
        case "$reply" in [Yy]*) do_hooks="yes" ;; *) do_hooks="no" ;; esac
      else
        ok "non-interactive — leaving hooks in place (re-run with --remove-hooks to remove)."
      fi ;;
  esac
  if [ "$do_hooks" = "yes" ]; then
    if "$CLAUDE_HOOKS_UNINSTALLER"; then
      ok "Claude Code hooks removed"
    else
      warn "Claude Code hook uninstaller exited non-zero — see its output above."
    fi
  fi
fi

# --- config: keep unless --purge -------------------------------------------------
say ""
say "Config directory"
if [ "$PURGE" -eq 1 ]; then
  if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR" && ok "purged $CONFIG_DIR" || warn "could not remove $CONFIG_DIR"
  else
    ok "$CONFIG_DIR does not exist — nothing to purge."
  fi
else
  if [ -d "$CONFIG_DIR" ]; then
    ok "left $CONFIG_DIR intact (your slots + config). Pass --purge to delete it."
  else
    ok "$CONFIG_DIR does not exist."
  fi
fi

say ""
say "agent-pods uninstalled."

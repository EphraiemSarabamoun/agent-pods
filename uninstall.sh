#!/usr/bin/env bash
# uninstall.sh — undo what install.sh did, conservatively.
#
# Removes the bin/* symlinks this repo placed in ~/.local/bin (only links that actually
# point back into THIS repo's bin/ are touched — a same-named link to something else is
# left alone). Offers to remove the Claude Code and Codex lifecycle hooks. Your config in
# ~/.config/pod (slots.json, config.sh) is LEFT INTACT unless you pass --purge.
#
#   ./uninstall.sh                 remove symlinks, offer to remove lifecycle hooks
#   ./uninstall.sh --remove-hooks  non-interactively remove Claude Code + Codex hooks
#   ./uninstall.sh --keep-hooks    non-interactively leave lifecycle hooks
#   ./uninstall.sh --purge         also delete ~/.config/pod (your slots + config)
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
POD_BIN="$REPO/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pod"
LOCAL_BIN="$HOME/.local/bin"
CLAUDE_HOOKS_UNINSTALLER="$REPO/hooks/claude-code/uninstall.sh"
CODEX_HOOKS_UNINSTALLER="$REPO/hooks/codex/uninstall.sh"

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
  # Walk the repo's bin/ for the names install.sh linked, including sourced _pod-*
  # helpers, and remove a link only when
  # it actually resolves back into THIS repo's bin — never a same-named foreign link.
  for f in "$POD_BIN"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
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

# --- offer to remove lifecycle hooks ---------------------------------------------
say ""
say "Agent lifecycle hooks"
do_hooks="no"
case "$HOOKS_CHOICE" in
  yes) do_hooks="yes" ;;
  no)  ok "leaving Claude Code and Codex hooks in place (--keep-hooks)" ;;
  ask)
    if [ -t 0 ]; then
      printf '  Remove the agent-pods Claude Code and Codex hooks? [y/N] '
      read -r reply
      case "$reply" in [Yy]*) do_hooks="yes" ;; esac
    else
      ok "non-interactive — leaving hooks in place (re-run with --remove-hooks to remove)."
    fi ;;
esac
if [ "$do_hooks" = "yes" ]; then
  for pair in "Claude Code|$CLAUDE_HOOKS_UNINSTALLER" "Codex|$CODEX_HOOKS_UNINSTALLER"; do
    name="${pair%%|*}"; script="${pair#*|}"
    if [ ! -x "$script" ]; then
      warn "no $name hook uninstaller at $script — skipping"
    elif "$script"; then
      ok "$name hooks removed"
    else
      warn "$name hook uninstaller exited non-zero — see its output above."
    fi
  done
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

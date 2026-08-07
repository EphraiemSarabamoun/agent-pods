#!/usr/bin/env bash
# uninstall.sh — undo what install.sh did, conservatively.
#
# Removes the bin/* symlinks and the modules/*/bin/* exec shims this repo placed in
# ~/.local/bin (only entries that actually point back into THIS repo are touched — a
# same-named link or script belonging to something else is left alone), and restores any
# <name>.pre-agent-pods file install.sh moved aside to make room. Offers to remove the
# Claude Code and Codex lifecycle hooks. Your config in ~/.config/pod (slots.json,
# config.sh) is LEFT INTACT unless you pass --purge.
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

# --- remove the entries that point back into this repo ---------------------------
say "Removing agent-pods commands from $LOCAL_BIN"
removed=0
restored=0
if [ -d "$LOCAL_BIN" ]; then
  # Walk every name install.sh could have installed — the repo's bin/ (including the
  # sourced _pod-* helpers) plus each optional module's bin/ — and remove an entry only
  # when it actually points back into THIS repo, never a same-named foreign one.
  for f in "$POD_BIN"/* "$REPO"/modules/*/bin/*; do
    [ -f "$f" ] || continue                    # unmatched glob stays literal under set -u
    base="$(basename "$f")"
    link="$LOCAL_BIN/$base"
    ours=0
    if [ -L "$link" ]; then
      target="$(readlink "$link" 2>/dev/null || true)"
      # resolve relative targets against the link's own directory before comparing
      case "$target" in
        /*) resolved="$target" ;;
        *)  resolved="$LOCAL_BIN/$target" ;;
      esac
      if [ "$target" = "$f" ] || [ "$resolved" = "$f" ]; then ours=1; fi
    elif [ -f "$link" ]; then
      # Module commands are installed as exec shims, not symlinks (their bootstrap
      # cannot survive a link — see install.sh step 4b). The generated marker line
      # names the exact target, and we compare it literally, so we only ever delete a
      # shim this repo wrote.
      shim_target="$(head -n 8 "$link" 2>/dev/null | sed -n 's/^# agent-pods-shim: //p' | head -n 1)"
      [ "$shim_target" = "$f" ] && ours=1
    fi
    [ "$ours" -eq 1 ] || continue
    rm -f "$link" && removed=$((removed + 1))
    # install.sh moves a colliding stranger aside as <name>.pre-agent-pods instead of
    # destroying it; now that our entry is gone, put the original back where it was.
    bak="$link.pre-agent-pods"
    if { [ -e "$bak" ] || [ -L "$bak" ]; } && [ ! -e "$link" ] && [ ! -L "$link" ]; then
      if mv "$bak" "$link" 2>/dev/null; then
        restored=$((restored + 1))
      else
        warn "could not restore $base from $base.pre-agent-pods — it is still there"
      fi
    fi
  done
fi
# The manager-name launcher (install.sh step 4c) is named from your config, not from
# the repo, so the walk above cannot have seen it. Resolve the same name and remove it
# only when it is the shim we wrote — its marker names pod-launch literally.
mgr_name="$( cfg="$CONFIG_DIR/config.sh"; [ -f "$cfg" ] && . "$cfg" >/dev/null 2>&1; printf '%s' "${POD_MANAGER_NAME:-}" )"
case "$mgr_name" in
  ""|manager|-*|.*|*[!A-Za-z0-9_-]*) : ;;
  *)
    link="$LOCAL_BIN/$mgr_name"
    if [ -f "$link" ] && [ ! -L "$link" ]; then
      shim_target="$(head -n 8 "$link" 2>/dev/null | sed -n 's/^# agent-pods-shim: //p' | head -n 1)"
      if [ "$shim_target" = "$POD_BIN/pod-launch" ]; then
        rm -f "$link" && { removed=$((removed + 1)); ok "removed the '$mgr_name' launcher"; }
      fi
    fi ;;
esac

ok "removed $removed command(s)"
[ "$restored" -eq 0 ] || ok "restored $restored pre-existing command(s) from *.pre-agent-pods"

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

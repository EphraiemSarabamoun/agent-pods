#!/usr/bin/env bash
# _pod-strip.sh — the pod status-strip format strings (status-left + status-right),
# defined in ONE place so pod-launch (new pods) and pod-auto (retrofit a live pod)
# can never drift. SOURCE it; do not exec. Exports POD_STRIP_LEFT / POD_STRIP_RIGHT /
# POD_STRIP_RIGHT_LEN. bash 3.2 safe.
#
# Comma gotcha (load-bearing): inside a #{?..} conditional, every style directive
# must be its own single-attr #[..] block — a comma inside #[..] that sits within a
# conditional is misparsed as the conditional's branch separator. OUTSIDE a
# conditional, comma-joined #[a,b,c] is fine. See the _DOT comment in pod-launch.
[ -n "${__POD_STRIP_LOADED:-}" ] && return 0
__POD_STRIP_LOADED=1

# status-left: the pod-name badge. Tinted orange (colour202) while FULL AUTO is on,
# near-black otherwise. #S is the session (= pod) name, e.g. "Rome Pod".
POD_STRIP_LEFT='#{?#{==:#{@full_auto},1},#[bg=colour202]#[fg=colour16],#[bg=colour16]#[fg=colour231]} #S Pod #[bg=colour233] '

# status-right: the FOCUSED window's identity card (#{@card}) + the clickable button
# row + clock. Each button is a range=user|<name> click target routed by
# pod-status-action; the same names are bound to keyboard chords in pod-launch.
# Buttons, left to right: ⚡/✋ fullauto · ⭐ star · ☰ summary · + newwin · ⚙ settings.
POD_STRIP_RIGHT='#[fg=colour252]#{@card}#[default]   #[range=user|fullauto]#{?#{==:#{@full_auto},1},#[bg=colour202]#[fg=colour16]#[bold] ⚡ AUTO ,#[bg=colour238]#[fg=colour245] ✋ MAN }#[norange]#[default] #[range=user|star]#[bg=colour178,fg=colour16,bold] ⭐ #[norange,default] #[range=user|summary]#[bg=colour55,fg=colour231,bold] ☰ #[norange,default] #[range=user|newwin]#[bg=colour28,fg=colour231,bold] + #[norange,default] #[range=user|settings]#[bg=colour24,fg=colour231,bold] ⚙ #[norange,default] #[fg=colour245]%a %H:%M '

POD_STRIP_RIGHT_LEN=120

export POD_STRIP_LEFT POD_STRIP_RIGHT POD_STRIP_RIGHT_LEN

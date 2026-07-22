# tmux gotchas

Read this before touching the status strip or anything that targets a tmux window. Every
entry here cost a real debugging session; the guards are in the code on purpose. They are
load-bearing. Removing one re-introduces the bug.

---

## The empty-target footgun

**Symptom.** A script meant to recolor / rename / stamp identity onto window `@3` instead
clobbers whatever window the user is currently focused on.

**Cause.** When a tmux window-id variable is empty, `tmux setw -t "$win"` (or
`set-option -t ""`, `display-message -t ""`, and the like) does **not** target nothing.
tmux resolves a blank `-t` to the **active** window. So a lookup that silently returned
empty turns every following per-window command into "do this to whatever's focused right
now."

**Fix.** Assert the window id is non-empty before any `-t "$win"` command, and abort if
it's blank. Always target by a **stable `@id`**, never a window index, because indexes
renumber when windows are killed (`renumber-windows on`), so an index captured a moment
ago can point at a different window now. Every spawn/detect/state path in the deck guards
this.

---

## Fuzzy prefix-match on session names

**Symptom.** `pod-launch` thinks the bare-prefix pod name (`pod`) is taken whenever any
numbered pod (`pod-7`) exists, so it never reuses the clean name; or a `pod-tell` to one
pod leaks into a sibling pod whose name is a prefix of it.

**Cause.** tmux target matching is **fuzzy by default**: `has-session -t pod` returns true
for a session named `pod-7` because `pod` is a prefix of `pod-7`. The same prefix-match
bites `list-windows -t pod` and friends.

**Fix.** Prefix the target with `=` to force an **exact-name** match:
`has-session -t "=$S"`, `list-windows -t "=$sess"`, `kill-session -t "=$s"`. Every
existence check and per-pod snapshot in the deck uses the `=` form. (This is a bash
concern only; in interactive zsh `=word` is command expansion, but these are bash
scripts.)

---

## display-menu: first item must be selectable, and `-c` from run-shell

**Symptom (first item).** Opening the `+` picker errors with "starting choice invalid" or
the menu refuses to open.

**Cause (first item).** `display-menu` requires its initial/starting choice to land on a
selectable item. If the first menu entry is a non-selectable separator or header, tmux
rejects the starting position.

**Fix (first item).** Make the first item of any `display-menu` a real, selectable entry.

**Symptom (`-c`).** The `+` spawn picker (or the `☰` summary popup) silently does nothing,
or breaks, when launched from the status-strip click.

**Cause (`-c`).** The status-click handler runs via a *backgrounded* `run-shell -b`. From
that context there is no reliable "current client" to attach a menu/popup to, but the `+`
action is a `new-window` whose `display-menu` *auto-resolves* the popup client on its own.
Forcing `-c <client>` from this backgrounded context breaks that auto-resolution.

**Fix (`-c`).** Do **not** pass `-c` from the backgrounded run-shell for the `+` / popup
auto-resolve case; let it resolve the client itself. **But** chained settings menus are
different: the `⚙` editor pops its 2nd/3rd menu from a menu item's *own* backgrounded
run-shell, which has no current client to auto-resolve, so those chained menus **do** need
`-c <client>` threaded through. Without it the chained menus silently no-op ("nothing
happens"). The rule: auto-resolving single popup means no `-c`; chained menu means thread
`-c`.

---

## Nested if-shell loses the mouse range

**Symptom.** A status-strip button (notably `✕`) stops firing; clicking it falls through
to a normal tab-select.

**Cause.** Mouse-event context (`#{mouse_status_range}`) is only valid at the **top
level** of the click binding. A *nested* `if-shell` loses the mouse context in its
deferred branch, so `#{mouse_status_range}` reads empty there and the button match never
happens. Relatedly, the `✕` `#[range]` region must sit inside exactly **one** conditional
(depth 1); wrapping it in an outer conditional that pushes it to depth 2 makes tmux fail
to register the clickable region at all.

**Fix.** Route all status clicks through a **single top-level `if-shell`** that hands the
range to a bash script (`pod-status-action`) which matches it on an argv captured at click
time, with no fragile format re-eval in a deferred branch. Keep the `✕` range at depth 1
in the window-status format.

---

## Black-on-black body background

**Symptom.** A worker window's body (or a tab) renders as unreadable black text on a dark
background, text effectively invisible.

**Cause.** Setting a window's body background to a dark/saturated color **without** also
setting a light foreground leaves the default (dark) text on a dark bg.

**Fix.** Every body bg must be paired with a light fg: `fg=colour231,bg=<dark-jewel-tone>`
(and `fg=colour16` on the near-white active-tab style). The worker palette in
`lib/palette` is restricted to dark jewel tones precisely so `fg=colour231` always reads
on them; never add a light or saturated code there. The manager body uses near-black
`colour234` with `fg=colour231` for the same reason.

---

## run-shell stdout pops a copy-mode overlay

**Symptom.** Clicking `+` to spawn a worker leaves the new window stuck on a "color
screen" / a copy-mode overlay of some text output.

**Cause.** A button action bound via `run-shell` has its **stdout captured by tmux and
shown as a copy-mode overlay**. Any script that prints to stdout from a button action
will dump that text over the window.

**Fix.** Button-action scripts (like `pod-add-worker` invoked from `+`) keep their stdout
**empty**: they log to a file (`$POD_STATE/*.log`) instead of printing. Bind actions with
`run-shell -b` (backgrounded) so even incidental output can't pop an overlay.

---

## workers.json: share the lock, write atomically

**Symptom.** Two near-simultaneous writers (a `+` spawn and a `✕` kill, or the mcp and a
manual spawn) drop each other's changes; a worker vanishes from the registry, or a killed
one lingers.

**Cause.** Concurrent read-modify-write on `workers.json` with no shared lock, or a
non-atomic write, races.

**Fix.** Every writer takes the **same** `workers.json.lock` via `fcntl.flock` before
read-modify-write, and writes via a temp file plus `os.replace` (atomic within the dir).
The lock file is shared across all writers: `pod-add-worker`, the kill path, and the mcp
all lock the identical path.

---

## send-keys submit race

**Symptom.** A pod-mail notification delivered to a hookless agent gets mangled, or its
Enter fires before the text has landed, or it lands while the agent was mid-type and
clobbers its input.

**Cause.** `send-keys` of literal text followed immediately by `send-keys Enter` can race
the terminal; Enter can outrun the text. And typing into a pane that's actively
streaming/typing clobbers it.

**Fix.** `pod-deliver`'s submit path: confirm the pane is **idle and settled** (its
content unchanged across a ~0.4s re-check) before submitting; send the literal text with
`-l`, then `sleep 0.15` before sending `Enter` so the text lands first; and only send
Enter at all in `submit` mode. `buffer` mode never presses Enter, so a clobber there is
at worst editable text, never a command run. See [comms.md](comms.md) for the full gate
list.

---

## Range nesting must stay at depth 1

**Symptom.** A status-strip `#[range]` button (the tab `✕`, a `status-right` button) stops
registering as a clickable region; clicks fall through to the underlying tab-select.

**Cause.** tmux only registers a `#[range=...]` region when it sits inside **exactly one**
conditional (`#{?...}`). An outer wrap that pushes the range to nesting **depth 2** makes
tmux silently fail to register the region.

**Fix.** Keep every `#[range]` at depth 1. For the manager tab (window 0, which has no `✕`),
use a *separate*, range-free `#{?#{==:#{window_index},0},...}` prefix that suppresses the
`✕` rather than wrapping the `✕` range in another conditional.

---

## Comma inside `#[...]` within `#{?...}` is misparsed

**Symptom.** A status format with styled, conditional content renders garbled — a style run
bleeds, or the conditional's true/false branches split in the wrong place.

**Cause.** Inside a `#{?...}` conditional, a **comma inside a `#[...]` style block** is read
as the conditional's `,`-branch separator. So `#{?cond,#[fg=red,bold]X,Y}` mis-splits.

**Fix.** Inside a conditional, make every style directive its own single-attr block:
`#[fg=red]#[bold]X` instead of `#[fg=red,bold]X`. **Outside** a conditional, comma-joined
`#[a,b,c]` is fine. (Relatedly, no tab style may carry `reverse` — under reverse every
`#[fg=...]` glyph renders swapped; active tabs swap bg/fg explicitly instead.)

---

## `=name` vs `=name:` session targeting on tmux 3.6b

**Symptom.** A `show-options`/`set-option` against a session errors `no such session: =x`,
even though the session exists and `has-session -t "=x"` succeeds.

**Cause.** The `=` exact-match prefix (see "Fuzzy prefix-match" above) is honored by
`has-session`, `list-windows`, and `display-message -t "=name:"`, but on tmux 3.6b
`show-options -t "=name"` (bare, no trailing colon) **rejects** the `=` form for session
targets.

**Fix.** For session-scoped `show-options`/`set-option`, target with the **`=name:`** form
(trailing colon) — `show-options -t "=${sess}:" @is_pod`. Or read the option via a
`display-message -p -t "=${sess}:" '#{@is_pod}'` format, which accepts it. (After an exact
`has-session -t "=name"` guard, a bare-name target also resolves deterministically, because
`cmd-find` tries exact before prefix.)

---

## The docked-feed scroll stack

**Symptom.** Mouse-wheel scrolling the chat in the docked summary pane does nothing, or
echoes raw `64;12;5M` mouse digits, or lags badly under a trackpad momentum-flick.

**Cause + fix (the whole stack, all load-bearing on tmux 3.6b):**

- The pane switches to the **alternate screen buffer** (`\033[?1049h`) so the 2s repaint
  loop leaves no scrollback trail (tmux pushes a cleared screen into history on every
  `\033[2J`).
- It enables **`1006;1000` mouse mode** on the pane. There is **no wheel→arrow translation
  in tmux 3.6b** — without the pane opting into a mouse mode, tmux's `WheelUpPane` binding
  routes to `send-keys -M`, which is silently dropped. With the mode on, wheel events arrive
  on stdin as SGR sequences (`\033[<64/65;x;yM`) and the pane parses them.
- The tty is put in **non-blocking raw-ish mode** (`stty -echo -icanon min 0 time 0`):
  `-echo` kills the raw digits the kernel echoed between reads, and `min 0 time 0` lets a
  single `dd` grab a whole buffered momentum-flood.
- Scroll input is drained **one gulp per frame** (one `dd bs=512 count=1`, tokens counted in
  pure bash). Do **not** loop the drain until dry: under a continuous ~60 ev/s trackpad
  stream a drain-until-empty loop never exits.

---

## `\x1f`, not tab, as the field separator (bash 3.2)

**Symptom.** A `read`-parsed `list-windows` row drops or shifts a field when one of the
fields is empty (an un-stamped `@work`/`@card`), corrupting the parse.

**Cause.** Tab is IFS-whitespace, so bash 3.2 collapses runs of it and **drops empty
fields** — an empty field silently shifts every later field. (`\x01` was an earlier attempt;
bash 3.2 ate it through the tmux→read pipeline.)

**Fix.** Separate `list-windows -F` fields with **`\x1f`** (US, the unit separator). It's
non-whitespace, so it splits cleanly and preserves empty fields, and survives the
tmux→`read` pipeline intact.

---

## run-shell hooks need POD_TMP/POD_CONFIG_DIR in the server env

**Symptom.** A server-side `run-shell` hook (rename, dock, kill, star, drag, feed) resolves
the **wrong** state paths when you've overridden `POD_TMP` / `POD_CONFIG_DIR` via
*environment* (rather than `config.sh`).

**Cause.** A hook subprocess inherits the tmux **server's** environment, not the shell that
launched the pod. `_pod-paths.sh` finds `config.sh` on its own, but an env-only override
never reaches the server, so the hook falls back to the defaults.

**Fix.** `pod-launch` propagates them into the server env with
`set-environment -g POD_TMP ...` / `set-environment -g POD_CONFIG_DIR ...` at launch, so
every server-side hook resolves the same roots the launcher did. (Harmless when they're the
defaults; these are host-wide, not per-pod.)

## `display-message -t <dead-window-id>` exits 0

**Symptom.** A "window still alive?" probe like
`tmux display-message -p -t "$wid" '#{window_id}' && echo alive` sees every corpse as
alive: dead-worker reclaim never fires, reap guards pass on dead windows.

**Cause.** tmux resolves a bad `-t` target leniently for `display-message`: on a dead
window id it exits **0** and prints an **empty** line instead of erroring (verified on
tmux 3.6b).

**Fix.** Judge liveness by the probe's **output**, never its exit code:
`[ "$(tmux display-message -p -t "$wid" '#{window_id}' 2>/dev/null)" = "$wid" ]`.
Same rule for any `#{session_name}` / `#{window_index}` probe — compare the value,
don't trust the return.

## Command sandboxes block the tmux socket entirely

**Symptom.** When the agent's subprocesses run in a command sandbox that denies
unix-socket connect (e.g. Claude Code's command sandbox, a CI runner, a container),
the deck looks perfectly healthy — windows, colors, the strip — but every agent is
blind: no roster at SessionStart, no journal, no pod-mail, no state dots from its own
hooks. `tmux ls` from inside the agent says `connect() → EPERM`.

**Cause.** The sandbox denies unix-socket connect from the agent's subprocesses (hooks,
Bash tool). The tmux server is alive and the pane genuinely sits in a pod — but every
`tmux` call the agent's side makes fails, so hooks that self-identify or read/write
window options silently no-op.

**Fix (built in).** Filesystem is the source of truth; the socket is a render/transport
upgrade. Everything gates on one probe (`pod_socket_ok`): when connect fails, hooks
self-identify from `$POD_WINDOW`/`$POD_AGENT_ID`/`$POD_SESSION` (exported by
pod-worker-bootstrap / pod-launch in the unsandboxed pane), `bin/pod` builds a
file-backed roster from `workers.json`, and state/work/last mirror to
`$POD_STATE/mirror/<pod>/<win>` files that the unsandboxed pod-foreign-state poller
reconciles onto the real tmux options. The normal path is byte-for-byte unchanged —
the fallback triggers ONLY on socket connect failure, never on empty output (an empty
list from a working socket is a genuinely dead pod; falling back there would resurrect
ghosts).

**Accepted degradation.** Under a blocked socket, hook-parity agents (Claude Code,
Codex) are fully functional — awareness, journal, mail, and state all ride files.
`send-keys` delivery to non-hook seats (Aider, plain shells) is unavailable — it
genuinely needs the socket; don't try to fix it. Badges/dots lag up to one poller
interval (~3s) instead of flipping instantly. Seats spawned before the upgrade lack
`$POD_WINDOW` — respawn them once.

**Diagnose.** `pod-doctor` from a pane inside the pod names the broken link, including
this one (its section 1 probes the socket explicitly).

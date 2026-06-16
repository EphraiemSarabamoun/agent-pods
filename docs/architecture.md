# Architecture

agent-pods is three rings around one state tree. The inner ring (the deck) is always
present and self-contained; the outer two rings (queue, mcp) are optional modules that
layer on top without the deck depending on them.

## The three rings

**1. The deck (`bin/`).** The interactive multi-agent tmux session: launch/attach a pod,
spawn and color and kill workers, the clickable status strip, the roster, the docked
summary pane, and pod-comms. This is what `pod-launch` gives you. It needs only tmux, jq,
python3, and the agent binaries you want to drive. Nothing here imports the queue or the
mcp.

**2. The queue (`modules/queue/`).** A thin metadata layer for driving more queued work
than you have live workers: stage prompt templates into per-task inbox dirs, queue them
with priorities, and dispatch them to freed workers. It's pure metadata over the deck's
existing per-task convention (`<task-id>/{prompt.txt, result.json, DONE}`); losing the
queue files costs dispatch convenience, not the work itself. Optional.

**3. The mcp (`modules/mcp/`).** Exposes the deck as Model-Context-Protocol tools so an
agent sitting in the manager seat can spawn, dispatch, poll, and read worker output
programmatically instead of clicking the strip. It reads the same state files and color
palette the deck does. Optional.

The dependency direction is one-way: queue and mcp call into the deck; the deck never
calls them. You can delete `modules/` entirely and the deck still runs.

## State layout

Everything ephemeral lives under one tmp tree, `$POD_TMP` (default `/tmp/pod/`), split
into three subdirs:

```
/tmp/pod/
├── state/                      # the deck's own runtime state
│   ├── workers.json            # the worker registry (one entry per worker window)
│   ├── workers.json.lock       # the shared fcntl lock every registry writer takes
│   ├── tmux_group.json         # which pod is PRIMARY + its manager window + host + tmux bin
│   ├── pod-foreign-state.pid   # singleton guard for the state poller
│   └── *.log                   # pod-add-worker etc. log here (never to stdout)
├── inbox/                      # the queue module's task dirs (only if you use the queue)
│   ├── _templates/             # <name>.tpl.txt prompt templates
│   ├── _queue/                 # queued task metadata
│   └── <task-id>/              # prompt.txt, result.json, DONE
└── comms/                      # pod-comms, PER POD
    └── <pod>/                  # <pod> = the tmux session (pod) name
        ├── channel.log         # the chat feed the summary pane renders
        ├── <window_id>.mbox    # a recipient's unread mailbox
        ├── <window_id>.read    # its read archive
        ├── <window_id>.hw      # pod-deliver high-water (lines already notified)
        ├── stars.log           # the pod's gold-star award log
        ├── stars/<window_id>.pending  # queued star prompt (delivered on next idle)
        └── work/<window_id>.log  # per-window work headlines (for the summary pane)
```

`workers.json` is the registry. Each worker carries its tmux window id, session, color,
agent id/type, model, effort, identity card, label, host, status, and current task. It's
written by `pod-add-worker`, the `✕` kill path, and the mcp; all three take the **same**
`workers.json.lock` and write atomically (temp file plus `os.replace`) so concurrent
spawn/kill/sync can't drop each other's entries.

`tmux_group.json` records which pod is *primary*, the one the queue and mcp target by
default, so running several pods at once doesn't confuse them. Only the primary writes
it; a second pod that launches while a live primary exists leaves it alone.

`pod-task.json` (also under `state/`) is the autonomous loop's state — `pod` (which pod
owns the loop) and `status` (`running`/`paused`/`done`). It's a host-global singleton
scoped by its `pod` field so one pod's loop can't terminate another's. See
[autonomy.md](autonomy.md).

The `comms/<pod>/` subtree is deleted when the pod closes (a `session-closed` hook runs
`pod-mail-gc`) and swept on launch if a same-named pod died without cleanup. It is keyed
by the pod's *name*, so a pod **rename** moves the whole subtree: the `session-renamed`
hook runs `pod-sync-pod-name`, which `mv`s `comms/<old>` to `comms/<new>`, updates the
primary record if it pointed at the old name, and re-stamps the `@pod_name` session option
(so the pod's chat history follows the rename instead of orphaning).

## How the pieces fit

**`bin/_pod-paths.sh`** is the one place the project resolves where it lives and what it's
configured to do. Every `pod-*` script sources it first:

```sh
POD_BIN="$(cd "$(dirname "$0")" && pwd)"; . "$POD_BIN/_pod-paths.sh"
```

It follows its own symlink chain back to the real `bin/` (so a symlinked install still
finds its siblings), then exports the `POD_*` vars: the tmux binary, the tmp roots
(`POD_STATE` / `POD_INBOX` / `POD_COMMS`), the session prefix, the manager seat's
name/card/command, the adapter dirs, the slots file, the color palette path, and the
`POD_ADAPTER` query tool. Use these vars instead of any hardcoded path; that's what makes
the repo relocatable.

**`config/config.sh.example` to `~/.config/pod/config.sh`** is the user's runtime config:
a plain shell file sourced by `_pod-paths.sh`. It's deliberately a flat shell file, not
TOML, because `_pod-paths.sh` runs on every status-strip refresh and must pay zero python
startup. Set only what you want to override (session prefix, manager command, tmp
location, poller tuning); anything omitted keeps its built-in default.

**`bin/_pod-common.sh`** adds the comms path helpers (`pod_dir_for`, `pod_chan_for`,
`pod_mbox`, `pod_read`, `pod_name`). Any script that touches mailboxes or the channel
sources it after `_pod-paths.sh` and routes every comms path through these helpers, so the
per-pod path scheme lives in one place.

**`adapters/*.toml` plus `bin/pod-adapter`** are the agent catalog and its sole reader.
The config (shell file) is the *runtime* knobs; the catalog (rich TOML) is the *agent*
knowledge: how to launch, detect, and label each agent. No script parses adapter TOML
directly; they all call `pod-adapter`. See [adapters.md](adapters.md).

**`lib/palette`** is the single source of the worker color list, read by both
`pod-add-worker` (bash) and the mcp (python), so the two can't drift.

**`bin/_pod-strip.sh`** is the single source of the status-strip format strings
(`status-left` badge + `status-right` button row + clock). Both `pod-launch` (new pods)
and `pod-auto install` (retrofitting the FULL AUTO pill onto a pre-existing pod) source it,
so the two paths can never drift.

**`bin/_mgr-runtime.sh`** carries the minimal manager runtime the queue/mcp dispatch path
and the FULL AUTO gate share: `mgr_current_pod` (resolve the caller's pod), `mgr_manager_window`
(window 0's id), `mgr_pod_auto_state` (`on`/`off`/`none`), and `mgr_full_auto` (the gate
predicate). Sourced, never executed.

## Pod identity: city names and `@is_pod`

A pod is **identified by a tmux session option, `@is_pod=1`**, not by a name pattern. New
pods are named after a random free **city** (`pod-city`: Rome, Kyoto, …), with the numeric
`<prefix>-N` series as the fallback when the city pool is exhausted. Override the pool with
`POD_CITIES` (space-separated single-word names). Because pods are city-named, the reaper,
the foreign-state poller, the rename hook, and the dispatch gate all recognize a pod by its
`@is_pod` stamp — a name regex would no longer work.

`pod-launch` stamps three options at creation, before the status formats first render:
`@is_pod=1`, `@full_auto=0` (autonomy is opt-in), and `@pod_name=<name>` (the rename hook's
record of the current name). It also propagates `POD_TMP` / `POD_CONFIG_DIR` into the tmux
*server* environment so server-side `run-shell` hooks (rename, dock, kill, star, drag,
feed) resolve the same paths the launcher did.

## FULL AUTO

Each pod has a **FULL AUTO** switch: the session option `@full_auto` (`1`/`0`), rendered as
the strip's `⚡ AUTO` / `✋ MAN` pill plus an orange status-left badge tint when on. Flip it
with the pill, `C-a a`, or `M-a` (all route through `pod-auto`).

The switch **gates automatic dispatch** in the queue module. In MANUAL mode (`@full_auto`
unset/`0`) `mgr-pick-next` holds the queue — it still polls completions but won't auto-pick
a worker; you dispatch by hand with `mgr-dispatch --tmux-window <@id>`. In AUTO mode the
manager may run the autonomous loop (see [autonomy.md](autonomy.md)). The gate **fails
OPEN** for non-pods: `mgr_pod_auto_state` returns `none` for any session without `@is_pod`,
and callers treat `none` as unrestricted, so a plain tmux session or a headless seat never
notices the switch exists. The switch's transitions also notify the manager (an mbox note,
or a typed resume trigger when a paused loop for this pod is found).

## The docked summary pane (mission control)

The pod's mission control is a **docked pane**, not a window. On the pod's first client
attach, a `client-attached` hook docks `pod-summary --pane` as a narrow **black column on
the right edge** of the current window (`pod-summary-pane on`), then self-unsets so later
reattaches don't force it back after a manual undock. Toggle it with the `☰` button, `C-a s`,
or `M-s`.

It's deliberately a non-modal pane (not a `display-popup`, which would grab the keyboard
and block typing to agents): focus stays in the agent pane, the pane auto-refreshes every
2s, and a session-scoped `session-window-changed` hook calls `pod-summary-pane follow` to
drag it along whenever you switch windows. A heavy cyan border marks the resize edge; drag
it and `follow` preserves the live width across moves. Click *into* the pane and it becomes
interactive (cursor nav, `⏎` open, `x` kill, wheel/`u`/`d` chat scroll, `q` undock — see
[keybindings.md](keybindings.md)).

Inside, the pane shows the **agent roster** on top — each agent's identity tag, live state
dot, an activity timer (time in the current state, from `@state_since`), and its `@work`
headline — and the **chat feed below**, newest-first. The roster comes from `pod-summary`;
the feed from `pod-feed`. The two meet through an in-memory cache: `pod-summary` runs
`pod-feed` in `POD_FEED_CACHE=1` mode once per 2s tick, which emits every wrapped chat line
as `ord|more|plen|line` records; scroll frames then assemble views from that array in pure
bash with **zero process spawns** (the scroll hot path). The manager's `👑` crown shows in
the roster only under FULL AUTO, mirroring the strip's window-0 crown gate.

## Script map

The deck, grouped by what it does. Read a script's header comment for the details; this is
just the orientation.

**Launch and lifecycle**
- `pod-launch`: create-or-attach a pod, stamp its identity (`@is_pod` / `@full_auto` / `@pod_name`), build the status strip + all key bindings + hooks, spawn the manager (window 0), and start the foreign-state poller. The integration hub — read it to see the full bind-key and hook set.
- `pod-city`: pick a random free city name for a new pod (overridable via `POD_CITIES`).
- `pod-shell`: the default manager seat, a shell that prints the `pod` roster.
- `pod`: print the roster of agents sharing this session.
- `pod-sync-pod-name`: the `session-renamed` hook — migrate a renamed pod's comms subtree + primary record + `@pod_name`.

**Spawn / kill / identity**
- `pod-add-worker`: the `+` action. Spawn a colored worker window, stamp its identity card, register it in `workers.json`.
- `pod-name`: pick a friendly worker name not already on a tab in this pod.
- `pod-kill-worker`: the `✕` action. Terminate a worker and unregister it.
- `pod-detect`: the one place "which agent is in this pane" is answered; caches `@agent_id` and friends on the window.
- `pod-sync-label`: on a double-click rename, push the new name into the registry.

**State and the strip**
- `pod-state`: stamp this pane's idle/busy/wait (+ `@state_since`) onto its window (the strip dot); for hook agents. Also delivers any queued gold-star prompt when it flips to idle.
- `pod-foreign-state`: the singleton poller that infers state, scrapes cards, clears unread pills, and delivers mail/stars for hookless agents.
- `pod-status-action`: route a status-strip button click (`fullauto` / `star` / `summary` / `newwin` / `settings` / `kill_*`).
- `pod-spawn-menu-build`: build the `+` agent/model picker from the catalog.
- `pod-settings-menu`: the `⚙` slot editor (chained menus, writes `slots.json`).
- `pod-summary`: the roster + chat panel — docked-pane (`--pane`) or modal-popup mode.
- `pod-summary-pane`: dock / undock / follow the non-modal summary column.
- `pod-feed`: render the chat feed (newest-first ANSI; `POD_FEED_CACHE` mode feeds the pane).
- `pod-drag-reorder`: reorder windows by tab-drag or `M-C`/`M-V` (manager immovable).

**FULL AUTO**
- `pod-auto`: flip / install / report a pod's `@full_auto` switch (the `⚡`/`✋` pill).
- `pod-task-wait`: block until a worker frees (or timeout / stop / auto-off); the autonomous loop's wake trigger.

**Comms**
- `pod-tell` / `pod-mail` / `pod-mail-check`: send (`direct` / `chat` / `@everyone`) / read / hook-surface mail; `pod-mail-check` also clears the unread pill.
- `pod-deliver`: universal per-agent delivery (context for hook agents, send-keys for the rest).
- `pod-mail-gc`: drop a pod's comms subtree when it closes (or sweep a dead same-named pod's at launch).
- `pod-work`: capture a per-turn work headline (the `@work` stamp feeding the summary).

**Gold stars**
- `pod-star`: award / revoke / list ⭐ (human-only; delivers as a real prompt on next idle).
- `pod-star-menu`: the `⭐` button / `C-a *` one-click star picker.

**Hooks**
- `hooks/claude-code/install.sh`: wire Claude Code's lifecycle events to `pod-state` / `pod-mail-check` / `pod-work` / `pod-awareness.sh`. The only agent with hooks shipped.
- `hooks/claude-code/pod-awareness.sh`: SessionStart roster plus stamp the window as that agent.

When in doubt, [gotchas.md](gotchas.md) is the file to read before touching the status
strip or anything that targets tmux windows.

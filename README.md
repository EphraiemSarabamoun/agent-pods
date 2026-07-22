# agent-pods

A grouped tmux deck of AI coding agents. Run several agents (or plain shells) side by
side in one tmux session, each on its own colored, clickable tab in a status strip you
can drive with the mouse: spawn a new agent with `+`, kill one with `✕`, pop a roster
or a dashboard, and let the agents message each other. Works with **Claude Code, Codex,
Aider, Cursor, Gemini, OpenCode, OpenClaw, or a plain shell**, anything with a TUI, and
nothing AI at all if that's what you have. Adding a new agent is a TOML file, not a code
change.

The design idea: the generic path is first-class. Any agent in any pane is a real
podmate (roster entry, color, state dot, mailbox). Per-agent lifecycle hooks are an
upgrade on top of that floor, not a requirement. Two adapters (Claude Code and Codex)
ship with them, and everything still works without them.

## What it looks like

The bottom of your terminal becomes a status strip. The pod is named after a random city;
window 0 is the "manager" seat, the rest are workers.

```
 Rome Pod   Claude Code · Opus 4.8 · high    ✋ MAN  ⭐  ☰  +  ⚙  Sat 14:03
 [👑 manager] [● 1:Steve ✕] [◐ 2:Mara ✕] [◆ 3:Otis ✕]
   ^grey home   ^green idle   ^orange busy ^yellow wait
```

Each tab carries:
- a **state dot**: green `●` idle, orange `◐` busy, yellow `◆` waiting on a prompt, grey `○` unknown
- the window index plus a friendly name (`1:Steve`)
- a `⭐` count if the human has awarded it stars, a red unread-count pill if it has mail
- a red `✕` to terminate that agent (with a confirm)

The right of the strip (`status-right`) shows the focused window's **identity card**
(agent, model, effort) and the clickable button row, left to right: the `⚡ AUTO` / `✋ MAN`
**FULL AUTO** pill, `⭐` stars, `☰` summary, `+` spawn, `⚙` settings. The pod summary is a
non-modal pane you dock on the right edge with `☰`, not a separate window.

## Requirements

- **tmux >= 3.3** (status-line mouse ranges plus the button regions)
- **jq** (registry plus group-state reads; the model-facing context tier — roster,
  journal, pod-mail — falls back to python3 if jq ever goes missing from the *agent
  process's* PATH, so agents never go silently blind. `pod-doctor` diagnoses that
  chain end to end)
- **python3 >= 3.11** (the adapter catalog uses `tomllib`)
- a POSIX shell. The scripts are bash 3.2 safe (works with the bash macOS ships).

Each agent you want to drive must be installed and on your `PATH` (`claude`, `codex`,
`aider`, and so on). agent-pods launches them; it doesn't bundle them. With none installed
you still get a deck of plain shells.

Model choices come from each installed agent on the current device. Claude Code and
Codex are queried through their local `/model` menus and Cursor through
`--list-models`. Agents without trustworthy account-scoped enumeration inherit their
own configured default rather than presenting a guessed catalog. See
[local model discovery](docs/adapters.md#discover-authoritative-local-models).

## Quickstart

```sh
git clone https://github.com/<you>/agent-pods.git
cd agent-pods
./install.sh            # symlinks bin/* onto your PATH; optionally wires agent hooks
pod-launch              # open your first pod
```

`install.sh` symlinks `bin/*` into `~/.local/bin` (make sure that's on your `PATH`) and
copies `config/config.sh.example` to `~/.config/pod/config.sh` for you to edit. If you
use Claude Code or Codex and want the richer integration (instant state dots, work
headlines, mail surfaced as context), let the installer wire its lifecycle hooks. See
[docs/adapters.md](docs/adapters.md) and the per-agent installer under
`hooks/`.

Then:

```sh
pod-launch              # NEW pod (named after a random free city: Rome, Kyoto, ...)
pod-launch mypod        # create-or-attach a pod named "mypod"
```

### A 60-second walkthrough

1. **Launch.** `pod-launch` opens a pod named after a random free city (`Rome Pod`); the
   numeric `pod-2`, `pod-3`, … series is the fallback when the city pool runs out. Window 0
   is the manager.
2. **Spawn workers.** Click `+` (or `C-a +` / `M-d`) to open the agent/model picker; pick
   one and it appears as a new colored tab. Or from any window:
   ```sh
   pod-add-worker --agent claude-code --model opus --effort high
   pod-add-worker --agent codex --model gpt5.5
   pod-add-worker                       # a plain shell worker (the universal floor)
   ```
   The `+` picker has ten quick-pick slots, edited via the `⚙` settings menu.
3. **See the roster.** Run `pod` from any window to list your podmates with each one's card,
   live status, color, stars, and which is "you".
4. **Talk.** `pod-tell Steve check the build` (direct), `pod-tell chat I'm rebasing`
   (quiet — reaches everyone, no badge), `pod-tell all freeze commits` (broadcast — badges
   every tab). Hook agents get mail delivered as context at their next turn; `pod-mail`
   reads it manually.
5. **Remember.** Every pod keeps a running **journal** — podmate joins, state flips, and
   curated `pod-note "..."` entries — injected into each agent at session start and
   refreshed as a per-turn delta, so agents stay aware of each other between messages.
6. **Watch.** Hit `☰` (or `C-a s` / `M-s`) to dock the **summary pane** on the right edge:
   the roster on top, the live chat feed below. It follows you as you switch windows; click
   into it to scroll and navigate.
7. **Go autonomous.** Flip `✋ MAN` to `⚡ AUTO` (the pill, `C-a a`, or `M-a`) to let the
   manager run the pod on its own — see [docs/autonomy.md](docs/autonomy.md).
8. **Reward.** Award a `⭐` with the gold-star button (`C-a *` / `M-g`). Stars are
   human-only; the awardee gets a real "gold star!" prompt the next time it's idle.

Every button has a keyboard chord — the full map is in
[docs/keybindings.md](docs/keybindings.md).

## Core concepts

**Pod vs manager vs worker.** A *pod* is one tmux session, the live cluster of agents
sharing it, named after a city and recognized by an `@is_pod` session stamp (not a name
pattern). Window 0 is the *manager* seat (the best agent you have installed by default, a
plain roster-printing shell if you have none, or whatever you pin with `POD_MANAGER_CMD`;
name it via `POD_MANAGER_NAME`). Every other window is a *worker*. If you run
agent-pods across machines, the host mesh is the *fleet*, but a pod is local to one host
and one tmux session. Rename a pod by double-clicking its badge (or `M-r`); its chat
history follows the rename.

**The buttons.** All status-strip clicks route through one handler:
- `⚡ AUTO` / `✋ MAN` toggles the pod's **FULL AUTO** switch.
- `⭐` opens the gold-star picker (human-only).
- `☰` toggles the docked summary pane.
- `+` opens a native menu built from the agent catalog; pick an agent plus model and it spawns a colored worker.
- `⚙` edits the ten quick-pick `+` slots (chained menus, saved to `~/.config/pod/slots.json`).
- `✕` on a tab terminates that worker (after a confirm). Window 0 has no `✕`.
- double-click a tab to rename the worker; drag a tab to reorder it (the manager is immovable). The new name flows into the registry.

**FULL AUTO.** Each pod has an autonomy switch (`@full_auto`, the `⚡`/`✋` pill). In MANUAL
mode you're the manager and the queue holds; flip it on and the manager can run the pod by
itself — decompose an objective, dispatch to idle workers, wake on each completion, repeat.
See [docs/autonomy.md](docs/autonomy.md).

**State dots.** Each window stamps `@cc_state` (idle/busy/wait). Agents with lifecycle
hooks stamp it themselves the instant their turn starts or ends; agents without hooks
get it inferred by a small background poller that watches their pane for changes. Either
way the strip shows idle-at-a-glance.

**pod-comms.** Agents message each other. `pod-tell Steve check the build` (direct),
`pod-tell chat …` (quiet, reaches everyone with no badge), `pod-tell all stand down`
(broadcast, badges every tab), `pod-mail` to read your inbox, and the docked summary pane
for a live Slack-style feed. Delivery is universal: a hook-capable agent gets the messages
delivered as context at its next turn (mailbox drained, pill cleared); a hookless agent
gets a one-line notification typed into its pane when it's idle. Direct and broadcast
messages stamp a red unread pill on the tab, cleared when the recipient catches up. On top
of chat, each pod keeps a running **journal** (`pod-note`, auto-fed from podmate
transitions) that agents receive at session start and as per-turn deltas. See
[docs/comms.md](docs/comms.md).

**Gold stars.** Award a `⭐` to a worker with the gold-star button / `C-a *` — stars are
**human-only** (agents can read the board but not award). A deliverable agent gets a real
"gold star!" prompt the next time it's idle.

**The roster.** Run `pod` from any window to list your podmates (manager plus every
worker) with each one's identity card, live status, color, stars, and which one is "you".

## Configuration

Runtime config is a plain shell file at `~/.config/pod/config.sh` (copied from
`config/config.sh.example` on install). Set only what you want to override; everything
else keeps its default. It's sourced by every pod script, so one `NAME=value` per line
is all it takes. The knobs you'll reach for most:

### Naming the manager seat

Window 0 (the manager) shows a name on its tab — `manager` by default. Give it a name of
your own, and optionally a *second* name it switches to while the pod runs itself in FULL
AUTO, so the tab alone tells you which mode you're in:

```sh
POD_MANAGER_NAME="Hermes"             # shown in MANUAL mode (✋)
POD_MANAGER_NAME_AUTO="Hermes Prime"  # shown while FULL AUTO is on (⚡)
```

Spaces are fine. If you set only `POD_MANAGER_NAME`, the rename is a visible no-op (both
modes show the same name). The switch is live: toggling FULL AUTO renames the tab, and it
also heals a tab still showing the old default `manager` from a pod launched before you
set these — no relaunch needed for a running pod. A fresh `pod-launch` picks it up from
the start.

### Choosing the manager agent

By default the manager seat becomes the best agent you actually have installed
(`claude-code`, then `codex`, `cursor`, `openclaw`), launched with that agent's default
model — or a plain roster-printing shell if none are present. Override the order, or pin
one outright:

```sh
POD_MANAGER_PREFER="codex claude-code"   # try codex first
POD_MANAGER_CMD=claude                    # pin the manager to a specific command
POD_MANAGER_CMD=/bin/bash                 # force the plain-shell manager
```

### Naming pods

New pods are named after a random free city; the numeric `<prefix>-N` series is the
fallback when the pool runs out. Override either:

```sh
POD_SESSION_PREFIX=pod                 # the <prefix>-N fallback series
POD_CITIES="Rome Kyoto Cairo Oslo"     # your own pool (single words)
```

### State location

All ephemeral state lives under one private per-user tmp tree
(`${TMPDIR:-/tmp}/agent-pods-$(id -u)` by default). Override it when needed:

```sh
POD_TMP="$HOME/.cache/agent-pods/runtime"
```

### Operator primer & memory

At each hook-enabled seat's session start (Claude Code and Codex), the deck injects a concise **role primer** — how to run the
pod (manager) or participate in it (worker) — plus any **operator memory** you've saved.
Grow that memory with `pod-remember "<lesson>"`; it's durable and cross-session (unlike the
per-pod journal `pod-note` feeds) and reaches every hooked seat you spawn afterward. `POD_PRIMER=0`
turns the injection off; `POD_OPERATOR_MEMORY` relocates the file.

If a seat runs in a command sandbox that can't reach the tmux socket, the primer also tells
that agent up front which pod features work from there (roster, journal, pod-mail — anything
that reads or exchanges) and which are blocked (spawning/killing workers, driving other
panes — anything that changes the deck). See Troubleshooting.

### Local and managed model catalogs

The `+` picker queries the agent installed on this device, so Claude Code automatically
reflects Bedrock, Vertex, Foundry, enterprise policy, and account-specific availability.
Run `pod-adapter refresh claude-code` to force an immediate re-query. No model IDs are
configured in agent-pods.

The complete annotated list of knobs lives in
[`config/config.sh.example`](config/config.sh.example).

## Troubleshooting

If agents don't seem aware of their pod — no roster at startup, no journal, no mail, or
state dots stuck grey — run **`pod-doctor`** from a pane inside the pod. It walks the
whole awareness chain end to end (tmux reachability, json tooling, this window's identity
stamps, the roster shape the hooks match on, whether your Claude Code `settings.json`
actually wires the hooks and points at live paths, plus a live emit probe) and names the
first broken link. It's read-only. Common causes it catches:

- **Hooks not loaded yet.** Lifecycle hooks load when an agent *starts* — a session
  launched before you ran the hook installer stays blind until you restart it.
- **A relocated repo.** If you moved or re-cloned the repo after installing, the hook
  paths baked into `settings.json` can point at files that no longer exist; re-run
  `hooks/claude-code/install.sh`.
- **jq missing from the agent's PATH.** The context tier falls back to python3, so
  awareness still works, but `pod-doctor` flags it (a login shell having jq doesn't put
  it on the agent process's PATH).
- **A command sandbox.** When the agent's subprocesses can't reach the tmux socket (some
  CI runners, containers, restricted shells), the deck automatically falls back to
  filesystem-based coordination; `pod-doctor` confirms that tier is engaged and that the
  seat carries the `POD_WINDOW` identity it needs. Seats spawned before that support
  landed need one respawn to pick it up.

## Add your agent

Teaching agent-pods a new agent is a TOML file: how to launch it, how to recognize it in
a pane, what models and efforts it offers. Drop a file in `adapters/` (or override one in
`~/.config/pod/adapters/`) and it shows up in the `+` menu, no code change. The full
walkthrough, field by field, is in [docs/adapters.md](docs/adapters.md).

## Optional modules

The base deck (spawn / kill / roster / summary pane / comms / stars) is self-contained.
Two optional modules layer on top:

- **queue** (`modules/queue/`): stage prompt templates into per-task inbox dirs and
  dispatch them to free workers (`mgr-stage` / `mgr-queue` / `mgr-pick-next` / `mgr-dispatch`
  / `mgr-poll`). For driving more queued work than you have live workers, and the substrate
  the FULL AUTO loop runs on.
- **mcp** (`modules/mcp/`): expose the deck as Model-Context-Protocol tools (`pod_spawn_window`,
  `pod_dispatch`, `pod_poll`, `pod_window_contents`, …) so an agent in the manager seat can
  spawn, dispatch, poll, and read worker output programmatically.

Neither is needed to use the deck interactively.

## Architecture

The repo is three rings, the deck (always present), the queue, and the mcp, over a
single private per-user runtime tree. Paths, config, and the adapter catalog meet in
`bin/_pod-paths.sh`. See [docs/architecture.md](docs/architecture.md) for the full map,
[docs/keybindings.md](docs/keybindings.md) for every chord and mouse action,
[docs/autonomy.md](docs/autonomy.md) for the FULL AUTO loop, and
[docs/gotchas.md](docs/gotchas.md) for the hard-won tmux details a contributor should
read before touching the status strip.

## License

MIT. See [LICENSE](LICENSE).

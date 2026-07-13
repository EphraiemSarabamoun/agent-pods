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
- **jq** (registry plus group-state reads)
- **python3 >= 3.11** (the adapter catalog uses `tomllib`)
- a POSIX shell. The scripts are bash 3.2 safe (works with the bash macOS ships).

Each agent you want to drive must be installed and on your `PATH` (`claude`, `codex`,
`aider`, and so on). agent-pods launches them; it doesn't bundle them. With none installed
you still get a deck of plain shells.

## Quickstart

```sh
git clone https://github.com/<you>/agent-pods.git
cd agent-pods
./install.sh            # symlinks bin/* onto your PATH; optionally wires agent hooks
pod-launch              # open your first pod
```

`install.sh` symlinks `bin/*` into `~/.local/bin` (make sure that's on your `PATH`) and
copies `config/config.sh.example` to `~/.config/pod/config.sh` for you to edit. If you
use Claude Code and want the richer integration (instant state dots, work headlines,
mail surfaced as context), let the installer wire its lifecycle hooks. See
[docs/adapters.md](docs/adapters.md) and the per-agent installer under
`hooks/claude-code/`.

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
pattern). Window 0 is the *manager* seat (a shell that prints the roster by default, or an
agent if you point `POD_MANAGER_CMD` at one). Every other window is a *worker*. If you run
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
single state tree under `/tmp/pod/`. Paths, config, and the adapter catalog meet in
`bin/_pod-paths.sh`. See [docs/architecture.md](docs/architecture.md) for the full map,
[docs/keybindings.md](docs/keybindings.md) for every chord and mouse action,
[docs/autonomy.md](docs/autonomy.md) for the FULL AUTO loop, and
[docs/gotchas.md](docs/gotchas.md) for the hard-won tmux details a contributor should
read before touching the status strip.

## License

MIT. See [LICENSE](LICENSE).

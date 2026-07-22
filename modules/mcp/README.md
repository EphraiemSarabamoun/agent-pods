# pod-manager MCP (optional module)

An MCP server that promotes the agent-pods manager-worker protocol to first-class
tools, so an **MCP-capable manager agent** can spawn, dispatch, poll, and peek at pod
workers with structured tool calls instead of shelling into `mgr-*` for every step.

This module is **optional**. The pod deck (tmux windows, the `+` button, `pod-tell`,
`pod-mail`) works without it. Install it only if your manager agent speaks MCP and you
want the queue + observability surface as tools.

## What it gives you over bare shell

- **Validated dispatch.** `pod_stage` checks a template's `required_vars` before staging.
- **Observability.** `pod_window_contents` peeks at a worker's live pane; `pod_status` /
  `pod_list_workers` report the roster + per-worker elapsed time.
- **Structured returns.** Every tool returns JSON the agent can branch on.

It is a thin wrapper: spawning shells out to the same colored-tmux-window primitive the
`+` button uses, and dispatch/poll/queue shell out to the `mgr-*` helpers in the queue
module (`modules/queue/bin`). The catalog of agents/models is never parsed here — that
stays in `bin/pod-adapter`.

## Tool surface

All tools are `pod_*`. Server name: `pod-manager`.

**Bootstrap** — `pod_init` (create the inbox + state trees, install default templates;
idempotent unless `force=True`).

**Discovery** — `pod_list_templates`, `pod_get_template`.

**Workers** — `pod_list_workers`, `pod_spawn_window` (spawn a colored adapter-backed
agent or generic-shell window in the active pod and register it), `pod_register_worker` (track an
existing window), `pod_window_contents` (peek a worker's pane via `capture-pane`).

**Dispatch** (wraps `mgr-*`) — `pod_stage`, `pod_queue`, `pod_dispatch`, `pod_poll`,
`pod_pick_next`, `pod_status`.

**Results** — `pod_read_result`, `pod_read_prompt`, `pod_list_inbox`.

**Intervention** (experimental) — `pod_send_input` (type into a running worker;
refuses the manager window).

**Group** — `pod_group_status` (active pod/session and live deck windows).

The first call should be `pod_init()`.

## Requirements

- Python **3.11+** (the adapter uses `tomllib`).
- The MCP SDK: `pip install "mcp>=1.5.0"` (ships `mcp.server.fastmcp.FastMCP`).
- A running **tmux pod** (launch the manager with `pod-launch`). Worker spawn /
  dispatch / send-input need an active session; without one those tools return a
  `tmux pod not active` hint.
- The **queue module** for dispatch/poll/queue: `modules/queue/bin` must contain the
  `mgr-*` helpers and `modules/queue/templates` the default templates + `_registry.json`.

## Install / run

The MCP server is intentionally **checkout-bound**. It wraps `bin/`, the queue
helpers, adapter catalog, templates, and palette from the same repository, so it is
not published as a standalone wheel that would duplicate and eventually drift from
those assets.

From the repository root, let `uv` create an isolated environment, install the MCP
SDK, and run the checkout-bound file. `--no-project` intentionally avoids writing a
lockfile or virtual environment into this repository:

```sh
uv run --isolated --no-project --with 'mcp>=1.5.0' \
  python modules/mcp/pod_manager_server.py
```

If the MCP SDK is already installed in your environment, direct execution is also
fine:

```sh
python3 modules/mcp/pod_manager_server.py
```

## Register with an MCP client

The server speaks MCP over **stdio**. Point your client at `uv` plus this checkout and
pass the `POD_*` env so it resolves the same paths as the rest of the pod.

Example (Claude Code's `~/.claude.json` / a project `.mcp.json`; the shape is the same
for any client that takes a `command` + `args` + `env`):

```json
{
  "mcpServers": {
    "pod-manager": {
      "command": "uv",
      "args": [
        "run", "--isolated", "--no-project", "--with", "mcp>=1.5.0",
        "python", "/path/to/agent-pods/modules/mcp/pod_manager_server.py"
      ],
      "env": {
        "POD_REPO": "/path/to/agent-pods",
        "POD_BIN": "/path/to/agent-pods/bin",
        "POD_MODULES": "/path/to/agent-pods/modules"
      }
    }
  }
}
```

If the MCP SDK is already installed for a particular interpreter, use the shorter
interpreter form instead:

```json
{
  "command": "python3",
  "args": ["/path/to/agent-pods/modules/mcp/pod_manager_server.py"]
}
```

## Environment variables

All are read at import time, with the fallbacks shown. Normally `_pod-paths.sh` (sourced
by the pod scripts) exports the first group for you; pass them through to the MCP client
env so the server resolves the same tree.

| Var | Purpose | Fallback |
| --- | --- | --- |
| `POD_REPO` | Repo root (for repo-relative path resolution) | this file's `../..` |
| `POD_BIN` | The `bin/` dir (pod-launch, pod-name, pod-adapter) | `$POD_REPO/bin` |
| `POD_MODULES` | Modules root (mgr-* + templates live under `queue/`) | `$POD_REPO/modules` |
| `POD_INBOX` | Inbox tree (`<task-id>/{prompt.txt,result.json,DONE}`, `_queue/<pod>/`, `_templates/`) | `$POD_TMP/inbox` |
| `POD_STATE` | State dir (`workers.json`, `tmux_group.json`, `log.jsonl`, `dispatched/<pod>/`, `completed/<pod>/`) | `$POD_TMP/state` |
| `POD_PALETTE` | Worker color palette (shared with `pod-add-worker`) | `$POD_REPO/lib/palette` |
| `POD_ADAPTER` | Path to the catalog reader | `$POD_BIN/pod-adapter` |
| `POD_TMUX` | tmux binary | resolved on `PATH` / `tmux_group.json` |
| `HOME` | Default cd target for spawned workers | the process's `$HOME` |
| `TMUX_PANE` | Set automatically when the server runs inside a tmux pane; used to resolve the manager's own pod | — |

## Notes

- **Tmux-only.** Workers are sibling windows in the manager's tmux pod, addressed by
  stable tmux window id (`@N`).
- `pod_spawn_window` accepts `agent_id`, `model`, and `effort`. A default
  **generic-shell** worker is interactive only and is deliberately ineligible for queue
  dispatch; pass an installed agent id for a dispatchable worker.

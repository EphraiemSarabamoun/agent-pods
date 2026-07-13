# Autonomous mode (the fire-and-poll loop)

A pod can run itself. With **FULL AUTO** on, the agent in the manager seat (window 0)
decomposes an objective into chunks, dispatches them to idle workers, sleeps until a
worker frees up, dispatches the next chunk, and repeats until the work is done. The
manager plans and routes; the workers are the hands.

There is **no skill or daemon that ships for this** — it is a *pattern* a manager agent
follows, built out of pieces that do ship: the queue module (`mgr-*`), the FULL AUTO
switch (`pod-auto`), and one blocking watcher (`pod-task-wait`). Any agent capable of
running shell commands and re-reading a small state file can run the loop.

## The loop, step by step

1. **Decompose.** The manager splits the objective into independent chunks, each a
   self-contained task a worker can finish and report on.
2. **Stage + queue.** For each chunk: `mgr-stage <template> ...` writes a prompt into
   `$POD_INBOX/<task-id>/prompt.txt`, then `mgr-queue <task-id>` adds it to the priority
   queue. (See [comms.md](comms.md) and the queue module for the template mechanics.)
3. **Dispatch to idle workers.** `mgr-pick-next` polls for completed tasks (freeing
   workers), then dispatches the highest-priority queued chunk to each freed/idle worker.
   `mgr-pick-next --all-idle` drains as many queue entries as there are idle workers in
   one shot.
4. **Arm the watcher (in the background).** The manager launches `pod-task-wait &`. This
   call **blocks** until a worker goes idle (touches a `DONE` sentinel), a safety
   heartbeat elapses, the loop is stopped, or FULL AUTO is flipped off.
5. **Wake and repeat.** When `pod-task-wait` exits, the manager is re-invoked — that
   re-invocation *is* the "an agent is idle, do the next thing" trigger. It calls
   `mgr-pick-next` again, dispatches the next chunk to the freed worker, and re-arms
   `pod-task-wait`.
6. **Stop** when the done-condition is met (queue empty and no in-flight workers), or
   when FULL AUTO is turned off.

The whole thing is **fire-and-poll, not synchronous babysitting**: the manager never sits
in a tight `while … sleep` loop. It fires work, arms one blocking watcher, and yields;
the watcher's exit is the only thing that wakes it.

## FULL AUTO gates the loop

The loop only runs while the pod's **FULL AUTO** switch is on (the strip's `⚡ AUTO` pill;
session option `@full_auto=1`; see [keybindings.md](keybindings.md) for how to flip it).

- **`mgr-pick-next` holds the queue in MANUAL mode.** It still polls for completions, but
  it will not auto-pick a worker. You dispatch by hand with an explicit
  `mgr-dispatch --tmux-window <@id>` (a deliberate act, always allowed).
- **`pod-task-wait` refuses to arm while the switch is off** and exits immediately with
  `auto-off`. A mid-flight flip-off wakes it within one poll (default 3s) so the manager
  pauses promptly.
- **Fail-OPEN for non-pods.** Outside a stamped pod (a plain tmux session, a headless
  seat), the gate is a no-op and the queue behaves exactly as it would without the switch.

When you flip FULL AUTO back **on**, `pod-auto` looks for a paused `pod-task` belonging to
this pod and, if it finds one, types a self-contained resume trigger into the manager's
REPL — so even a freshly-compacted manager can pick the loop back up from the state file
alone.

Two helpers keep the loop honest without you watching it:

- **`pod-auto-brief`** (wired into the manager's per-prompt hook by the Claude Code hook
  installer) injects the switch's meaning into the MANAGER only: with FULL AUTO on, "you
  are the autonomous manager — run objectives through this loop"; with it off and a
  paused task on file, a one-liner naming the paused objective so it isn't forgotten.
  Workers and quiet manual pods cost zero context.
- **Queue self-healing** (`mgr-poll`): a task assigned to a worker whose window died is
  requeued automatically (the dispatched archive is restored before the dead registry
  row drops, so an assignment can never vanish), and once the queue fully drains,
  finished worker windows are closed so a long-running loop doesn't accumulate idle
  agents (`MGR_REAP_FINISHED_WORKERS=0` to keep them).

## State: `pod-task.json`

The loop's state lives in one host-global file, `$POD_STATE/pod-task.json`. It carries at
least:

- `pod` — which pod owns this loop (so a second pod's flip can't terminate the primary's
  loop).
- `status` — `running` | `paused` | `done`. `pod-task-wait` honors a terminal
  `done`/`paused` only when the `pod` field matches the caller's pod (or, for files
  written before the field existed, when the caller is the recorded primary).

The manager owns this file: it sets `running` when it starts, `paused` when FULL AUTO goes
off, `done` when the objective is complete.

## `pod-task-wait` exit reasons

`pod-task-wait [timeout_seconds]` (default `1200` = a 20-minute safety heartbeat) prints
exactly one reason and exits. The manager polls regardless of the reason; it's
informational:

| Reason | Meaning |
| --- | --- |
| `idle-change` | a `DONE` sentinel appeared or disappeared — a worker finished. The clean, protocol-native signal. |
| `timeout` | the safety heartbeat elapsed with no `DONE` change. Lets the manager wake anyway and sweep for workers that went idle *without* a `DONE` (errored, never-tasked, stuck at a prompt). |
| `stopped` | this pod's `pod-task.json` was marked `done`/`paused` (a stale watcher self-ends). |
| `auto-off` | the pod's FULL AUTO switch is off. The manager should pause: mark `status` `paused`, dispatch nothing, don't re-arm. |

Override the poll interval with `POD_TASK_WAIT_POLL=<secs>` (default 3).

## Worked example

A minimal loop body the manager runs each time it wakes:

```sh
# 1. stage + queue the chunks (once, up front)
for chunk in "audit the auth module" "audit the api layer" "audit the cli"; do
  tid=$(mgr-stage audit context="$chunk" task_body="$chunk")
  mgr-queue "$tid" --priority 100 --description "$chunk"
done

# 2. each wake: free finished workers, dispatch to every idle one
mgr-pick-next --all-idle

# 3. block until the next worker frees (or timeout / stop / auto-off)
reason=$(pod-task-wait)        # the manager re-invokes itself when this returns

# 4. decide: queue empty + no in-flight workers -> mark done; else loop back to step 2
```

In practice the manager re-runs steps 2–4 on each re-invocation rather than looping inside
one shell call — that's the fire-and-poll shape: dispatch, arm one watcher, yield, wake,
repeat. The `reason` (`auto-off`/`stopped`) tells it when to pause or stop instead of
re-arming.

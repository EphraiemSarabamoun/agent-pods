# Queue module — fire-and-poll task dispatch

An OPTIONAL layer on top of a pod. It lets the manager hand self-contained
subtasks to worker windows and collect their results asynchronously, instead of
driving each worker's REPL turn by turn. The protocol is **fire-and-poll**: the
manager stages a prompt, queues it, dispatches it at an idle worker, and then
polls a `DONE` sentinel between its own turns. Workers never talk back through a
live channel — they write a result file and touch a sentinel.

This module has no durability or git-state layer: everything lives under the
pod's tmp tree (`$POD_INBOX` / `$POD_STATE`) and is gone when that tree is
cleared. It is a convenience over the raw inbox protocol, not a database.

## The inbox protocol

Each task gets a directory `$POD_INBOX/<task-id>/` (by default under the private
per-user `$POD_TMP` runtime tree):

- `prompt.txt` — the full task prompt the worker reads (staged by `mgr-stage`).
- `result.json` — the worker's structured result:
  `{status: "done"|"blocked"|"partial", answer: ..., reasoning: ..., proposed_memory_additions: [...]}`.
- `DONE` — an empty sentinel the worker `touch`es as its **last** action, so the
  manager only reads `result.json` after it is complete.

Supporting state lives under `$POD_STATE` (also under `$POD_TMP` by default):

- `workers.json` — the worker registry (written by `pod-add-worker`; this module
  reads it to find idle workers and flips them busy/idle).
- `tmux_group.json` — records which pod is primary + which window is the manager
  (so dispatch never fires into the manager seat).
- `log.jsonl` — append-only dispatch/completion audit trail.
- `dispatched/<pod>/` — archived queue files for that pod's in-flight tasks.
- `completed/<pod>/` — durable completion markers used by `pod-task-wait` so a
  concurrent poll cannot hide a just-finished task.

Queue files live under `$POD_INBOX/_queue/<pod>/`; templates under
`$POD_INBOX/_templates/`. Copy or symlink this module's `templates/*.tpl.txt`
into `$POD_INBOX/_templates/` at setup so `mgr-stage` can find them.
Task ids remain globally unique because their prompt/result directories retain the
stable `$POD_INBOX/<task-id>/` contract, but schedulable queue and archive records are
strictly pod-scoped. One pod therefore cannot consume another pod's queue head.

Ghost queue entries (a queue file whose staged `prompt.txt` has vanished) are
quarantined to `$POD_INBOX/_state/dead/` at auto-pick time, so a broken entry
can never sit at the queue head blocking every lower-priority task.

## Commands

All live in `modules/queue/bin/`; add that dir to your PATH (or call by path).

- `mgr-stage <template> [--id <id>] [<key>=<value>]...` — fill a template's
  `{{key}}` placeholders into `$POD_INBOX/<id>/prompt.txt`. `{{task_id}}` is
  always available. Prints the task-id. Auto-allocates `<template>-<N>` if no
  `--id`.
- `mgr-queue <task-id> [--priority N] [--description S] [--template T] [--deps id,id]`
  — add a staged task to the queue. Lower priority number = dispatched first.
  (`--deps` is recorded but not enforced — order with priority.)
- `mgr-dispatch [--task <id>] [--tmux-window <@id>] [--print-only]` — fire the
  highest-priority queued task (or `--task`) at the first idle worker (or a
  specific `--tmux-window`) via `tmux send-keys`. A registry-idle worker only
  qualifies when its LIVE window agrees (alive, in the calling pod, `@cc_state`
  idle); busy/wait windows are never interrupted, and cross-pod targets are
  refused. Marks the worker busy, stamps the board (`@work`/`@cc_state`), and
  logs the assignment to the pod's channel feed. A durable `dispatching` record
  plus signal rollback lets `mgr-poll` recover an interrupted dispatcher without
  silently losing or blindly duplicating the task.
- `mgr-poll [--quiet] [--json]` — sweep for `DONE` sentinels and flip completed
  workers back to idle (clearing their `@work` headline). Requeues the task of
  any worker whose window died mid-assignment, and — once the queue is fully
  drained — closes finished worker windows via `pod-kill-worker`. Idempotent.
- `mgr-pick-next [--all-idle] [--print-only]` — composite: poll, then dispatch
  one queued task per freed/idle worker (idle = registry AND live tmux agree).
  A single dispatch failure is logged and the batch continues. Call this at the
  top of every manager turn so the queue keeps draining.
- `mgr-status [--json]` — print the pod's FULL AUTO / manual mode, workers,
  queue, and recent completions (`full_auto: true|false|null` in `--json`).

## Environment knobs

- `MGR_REAP_FINISHED_WORKERS` (default `1`) — when a `mgr-poll` sweep finds the
  queue fully drained, close each worker window whose task just completed
  (guarded: window alive, not the manager, registry idle, live state not
  busy/wait). Set to `0` to keep finished workers open for reuse.
- `MGR_DISPATCH_RECOVERY_SECONDS` (default `30`) — grace period before `mgr-poll`
  heals a stale pre-delivery `dispatching` transaction.

## Templates

Four canonical shapes ship here and are wired in `_registry.json`
(`audit`, `execute`, `investigate`, `plan`). Each is a plain text file with
`{{var}}` placeholders and a COMPLETION PROTOCOL footer that tells the worker to
write `result.json` then `touch DONE`. Drop a new `.tpl.txt` in `templates/`
(and an entry in `_registry.json`) to add a shape.

## Canonical pattern

```sh
tid=$(mgr-stage audit --id find-todos-1 \
        context="..." scope="src/" \
        categories="bug | cleanup | docs" output_schema="{...}")
mgr-queue "$tid" --priority 100 --description "find TODOs" --template audit
mgr-pick-next            # poll completions + dispatch to a freed worker
```

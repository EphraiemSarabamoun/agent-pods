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

Each task gets a directory `$POD_INBOX/<task-id>/` (default `$POD_INBOX` is
`/tmp/pod/inbox`):

- `prompt.txt` — the full task prompt the worker reads (staged by `mgr-stage`).
- `result.json` — the worker's structured result:
  `{status: "done"|"blocked"|"partial", answer: ..., reasoning: ..., proposed_memory_additions: [...]}`.
- `DONE` — an empty sentinel the worker `touch`es as its **last** action, so the
  manager only reads `result.json` after it is complete.

Supporting state lives under `$POD_STATE` (default `/tmp/pod/state`):

- `workers.json` — the worker registry (written by `pod-add-worker`; this module
  reads it to find idle workers and flips them busy/idle).
- `tmux_group.json` — records which pod is primary + which window is the manager
  (so dispatch never fires into the manager seat).
- `log.jsonl` — append-only dispatch/completion audit trail.
- `dispatched/` — archived queue files for in-flight tasks.

Queue files live under `$POD_INBOX/_queue/`; templates under
`$POD_INBOX/_templates/`. Copy or symlink this module's `templates/*.tpl.txt`
into `$POD_INBOX/_templates/` at setup so `mgr-stage` can find them.

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
  specific `--tmux-window`) via `tmux send-keys`. Marks the worker busy.
- `mgr-poll [--quiet] [--json]` — sweep for `DONE` sentinels and flip completed
  workers back to idle. Idempotent.
- `mgr-pick-next [--all-idle] [--print-only]` — composite: poll, then dispatch
  one queued task per freed/idle worker. Call this at the top of every manager
  turn so the queue keeps draining.
- `mgr-status [--json]` — print workers + queue + recent completions.

## Templates

Five canonical shapes ship here, four of which are wired in `_registry.json`
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

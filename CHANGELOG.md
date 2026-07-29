# Changelog

## The leak guard stops publishing its own denylist, and your manager gets a launcher

- **`test/no-private-leaks.sh` no longer carries the private terms.** The guard exists so
  no name, path, host or persona from a private upstream tree can be dragged into this
  one — but it did that by hardcoding the list of terms, in a public file, in a public
  repo. A denylist is a map of exactly what it is hiding, so the guard was publishing the
  inventory it protects: usernames, home paths, machine names, private repo names. The
  mechanism stays here; the terms move out. It now reads one regex per line from
  `$POD_PRIVATE_PATTERNS` (default `~/.config/pod/private-patterns.txt`) and **skips,
  exit 0, when there is no such file** — a fork has no private identifiers of ours to
  leak, so there is nothing to check, and CI stays green without shipping a wordlist.
  `--require` inverts that for the pre-publish run, where a silent skip is the dangerous
  case: no patterns configured is then a failure, not a pass. The scan itself is
  unchanged (same paths, same LICENSE-copyright exemption, still case-insensitive).

- **`POD_MANAGER_NAME` now installs a launcher by that name.** Name the manager seat
  `Hermes` and `install.sh` puts a `hermes` command on your `PATH` that opens or attaches
  a pod, identical to `pod-launch` (`hermes mypod` targets one) — the deck answers to
  whatever you call it. The name comes from your local config at install time, so nothing
  persona-specific enters the repo. Claimed only when free: if any command already answers
  to that name anywhere on `PATH`, the installer warns and leaves both alone rather than
  shadowing it, since a name you chose is trivial to change. Names with spaces or shell
  metacharacters are skipped, as are collisions with an existing `pod-*` command.
  `uninstall.sh` removes it, matching only the shim it wrote.

## Continuous integration, and two doc corrections

- **CI (`.github/workflows/ci.yml`).** The test suite existed but nothing ran it. A
  push/PR workflow now runs ten checks — `check-adapters`, `lint-tmux-targets`,
  `no-private-leaks`, `check-install-modes`, `check-model-policy`,
  `check-context-emit`, `check-primer`, `check-sandbox-fallback`,
  `test-adapter-discovery-timeout`, `check-safety-invariants` — on **both**
  `ubuntu-latest` and `macos-latest`. The macOS leg is the point, not padding: the
  scripts are bash 3.2 safe and BSD/GNU portable on purpose, and only a macOS runner
  catches a `stat -c` or a GNU-only `date` before it ships. The step runs every check
  and fails once at the end, so one red run reports all faults instead of only the
  first. `ripgrep` is installed deliberately — `check-model-policy.sh`'s
  "no hardcoded model catalog" assertion is an `if rg ...` that silently *passes* when
  `rg` is missing, so without it that check was a no-op reporting success.
- **`parity-sandbox.sh` runs advisory-only, in its own job.** Several of its assertions
  are races rather than invariants (the rename section sleeps a fixed 0.8s while the
  `session-renamed` hook is backgrounded with `run-shell -b` and writes its feed line
  last, measured at 0.80s–2.85s end to end; the docked-pane scroll checks sleep
  0.2–0.25s against a 2s repaint tick). Gating on it would paint correct commits red on
  a loaded shared runner. Once those fixed sleeps become bounded polls on the terminal
  condition, drop `continue-on-error` and fold it into the matrix.
- **`config/config.sh.example` no longer points at a file that does not exist.** Line 4
  advertised `~/.config/pod/slots.toml`; nothing in the project reads that path, and
  `install.sh` copies this file verbatim to `~/.config/pod/config.sh`, so the wrong name
  was planted in every installation. The real files are `adapters/*.toml` (overridable
  at `~/.config/pod/adapters/*.toml`) for the catalog and `~/.config/pod/slots.json`,
  seeded by `install.sh` and edited via `⚙`, for the ten quick-pick slots.
- **`docs/keybindings.md` no longer claims `j`/`k` scroll the docked chat.** The table
  grouped them with the arrow keys as mode-dependent, but only the arrow branch in
  `bin/pod-summary` is guarded on pane mode; `j`/`k` move the roster card cursor in both
  modes. The row is now split, so the chat-scroll keys a reader reaches for (arrows,
  wheel, `u`/`d`) are the ones that actually scroll.

## Operator primer, memory, and sandbox notices

- **Operator primer.** At each seat's session start, `pod-primer` injects a concise,
  role-gated primer (as `additionalContext`, like the journal): a manager seat gets
  "how to run the pod" (`pod` / `pod-tell` / the `mgr-*` fire-and-poll loop), a worker
  gets the lighter completion contract. Generic primers ship in
  `lib/primer/{manager,worker}.md`; role is the pod's manager window. `POD_PRIMER=0`
  silences it. Wired into both the Claude Code and Codex hook installers.
- **Operator memory.** `pod-remember "<lesson>"` appends to a durable, cross-session
  file (`~/.config/pod/operator-memory.md`) that `pod-primer` injects into every seat
  you spawn afterward — distinct from `pod-note`, which is one pod's ephemeral journal.
- **Proactive sandbox notice.** When a seat's tmux socket is blocked (a command
  sandbox), `pod-primer` tells the agent up front which pod features work from that
  seat (reads + comms, via files) and which are blocked (deck changes).
- **Reactive sandbox notice.** `pod_require_socket` makes the deck-changing commands
  (`pod-add-worker`, `pod-kill-worker`, `pod-auto`) fail with a clear "blocked in this
  command sandbox — here's what still works" message instead of a cryptic tmux error.
  Read/exchange commands stay silent; the normal (socket-reachable) path is unchanged.
- `test/check-primer.sh` covers role selection, memory injection, both notices, and
  that the normal path stays silent.

## Sandboxed-seat support: the tmux socket is an upgrade, files are the truth

Some environments run the agent's subprocesses in a command sandbox that denies
unix-socket connect (Claude Code's command sandbox, CI runners, containers). There
the tmux client→server socket is unreachable from hook subprocesses (`connect()` →
EPERM) while the deck itself renders fine — agents sat blind and mute in a healthy-
looking pod. Every fallback gates on ONE probe (`pod_socket_ok`, memoized per
process): socket reachable → byte-for-byte today's behavior; socket blocked → files.

- **Identity as environment.** `pod-worker-bootstrap` and `pod-launch` export
  `POD_WINDOW` + `POD_AGENT_ID` into every seat from the (unsandboxed) pane shell.
  `pod-state`, `pod-mail-check`, `pod-work`, `pod-last`, `pod-brief`, and `pod-tell`
  resolve self-identity socket-first, env-fallback.
- **File-backed roster.** `bin/pod` rebuilds the roster from `workers.json` +
  `tmux_group.json` (+ mirror state) when — and only when — the socket connect
  fails, same `instance(s):` shape, so the awareness hook injects a real roster.
- **Mirror files + reconciler.** Sandboxed hooks write per-window state/work/last to
  `$POD_STATE/mirror/<pod>/<win>*`; the unsandboxed `pod-foreign-state` poller
  applies them onto the real tmux options (and journals transitions, heals stale
  unread pills). The strip/roster/badge render paths are completely untouched —
  data flows agent → file → poller → tmux, never sandboxed-agent → socket.
- **Journal-delta awareness.** Under a blocked socket `pod-brief refresh` emits new
  journal lines (per-reader cursor) instead of the live-window delta it can't take.
- **Sending works too.** `pod-tell` from a sandboxed seat rebuilds the recipient
  table from the registry; mbox deposits are pure file appends.
- **Accepted degradation** (documented in docs/gotchas.md): `send-keys` delivery to
  non-hook seats needs the socket and stays unavailable in sandboxes; dots/badges
  lag up to one poller tick (~3s) instead of flipping instantly.
- `pod-doctor` probes the socket first and names this state explicitly;
  `test/check-sandbox-fallback.sh` runs the acceptance tests against a blocked-socket
  stub and guards the normal path stays socket-driven.

## Context injection hardening + pod-doctor

- **jq is no longer a silent single point of failure for agent awareness.** Every
  model-facing hook payload (SessionStart roster, journal boot, podmate deltas,
  pod-mail delivery, the FULL AUTO stance) used to be gated on `command -v jq || exit`.
  On a machine where the agent process's PATH lacked jq, the deck looked perfectly
  healthy — windows, colors, state dots — while every agent stayed blind to its own
  pod. New `pod_emit_ctx` / `pod_json_get` helpers (`bin/_pod-paths.sh`) fall back
  jq → python3 (already a hard dep of `hooks/*/install.sh`) → raw stdout, and
  `test/check-context-emit.sh` guards the regression on both tool paths.
- **`pod-doctor`.** Read-only diagnosis of the awareness chain, for exactly the
  "my agents don't know they're in a pod" report: environment, json tooling, window
  stamps, roster shape, hook wiring in the settings.json the agent actually reads
  (including dead absolute paths after a repo move), a live emit probe, and manager
  naming. Run it from a pane inside the pod; it names the first broken link.
- **Manager persona naming heals stale tabs.** `pod-auto`'s mode rename previously
  refused to touch a manager tab still named `manager` from a pod launched before
  `POD_MANAGER_NAME` / `POD_MANAGER_NAME_AUTO` were configured (exact-match guard).
  It now renames any pod-owned name (either configured mode name or the shipped
  default) and still leaves hand-renamed tabs alone. `config.sh.example` shows the
  persona-pair pattern.

## Second parity sync

- **The pod journal.** Every pod keeps a running `journal.md` — auto-fed from podmate
  transitions (joins, departures, state flips with a one-line headline) and hand-fed
  with `pod-note "..."`. `pod-brief boot` (SessionStart) hands a fresh agent the tail;
  `pod-brief refresh` (each prompt) injects only what changed among podmates since that
  agent's last turn. See the journal section of `docs/comms.md`.
- **Mail auto-delivery.** `pod-mail-check` now injects the FULL unread messages as
  context, atomically drains the mailbox, and clears the pill — previously it only
  nudged ("run pod-mail"). `pod-mail` stays as the manual path and self-heals stale
  pills.
- **Codex hook parity.** Codex fires Claude-style lifecycle hooks (`~/.codex/hooks.json`),
  so it's promoted from the poll/send-keys floor to a first-class hook agent:
  `hooks/codex/install.sh` (offered by `./install.sh`), `bin/pod-codex-state`, and the
  adapter flip. State dots flip instantly; pod-mail reaches Codex silently as context.
  The poll floor remains the documented fallback.
- **One-line agent summaries.** `pod-summarize` stamps `@summary` ("what is this agent
  doing") from an explicit `<!-- STATUS: "..." -->` tag in the agent's output (free), or
  a user-configured `POD_SUMMARIZE_CMD` (off by default). `pod` / `pod-summary` / the
  journal prefer it and NEVER render a raw prompt as a status headline; `pod-last`
  (Stop hook) stamps the last-reply digest they fall back to.
- **Richer `pod` roster.** FULL AUTO tag in the header, live `runtime=` state per
  window (with a `/polled` marker for inferred state), `↳ status:` and `↳ on:/last:`
  lines, and first-task 🐣 placeholders.
- **Queue self-healing.** `mgr-poll` requeues a dead worker's task (archive restored
  atomically BEFORE the registry row drops) and, once the queue drains, reaps finished
  worker windows (`MGR_REAP_FINISHED_WORKERS=0` disables). `mgr-dispatch` re-checks the
  live window state at the last moment (never interrupts busy/wait), refuses cross-pod
  targets, quarantines ghost queue entries instead of letting them block the queue
  head, matches `--task` ids exactly, and stamps the live board + feed on dispatch.
  `mgr-stage` allocates ids atomically and substitutes templates without recursive
  expansion; `mgr-queue` validates priority bounds.
- **Spawn-race gate.** Workers launch through `pod-worker-bootstrap`, which holds the
  agent until `pod-add-worker` finishes stamping identity — the foreign-state poller
  can no longer misclassify a half-launched pane.
- **Stuck-wait rescue.** `PostToolUse -> pod-state busy posttool` clears a yellow ◆
  that survived an answered in-agent prompt, as a one-read no-op on ordinary tool calls
  (previously every tool call stamped busy + redrew).
- **FULL AUTO extras.** A skippable ⚡ celebration popup on the ON flip
  (`POD_AUTO_ANIM=0` disables) and a journal line per flip; `pod-auto-brief` tells the
  manager (only) what the switch means for the current prompt.
- **tmux footgun fixed:** `display-message -p -t <dead-window-id>` exits 0 with empty
  output, so liveness probes must compare output, not exit codes. Also: the kill
  confirm no longer pops a "returned 1" overlay on decline, and a renamed pod no
  longer leaves a zombie session when its manager exits.

## Parity sync

- **City-named pods.** New pods get a random free city name (`pod-city`; override the pool
  with `POD_CITIES`), with the numeric `<prefix>-N` series as the fallback. Pods are now
  recognized by an `@is_pod` session stamp, not a name pattern.
- **FULL AUTO switch.** A per-pod `@full_auto` session option (`pod-auto`), rendered as the
  `⚡ AUTO` / `✋ MAN` strip pill, gates automatic dispatch in the queue module. Flip via the
  pill, `C-a a`, or `M-a`; fails OPEN for non-pods.
- **Autonomous loop.** A documented fire-and-poll pattern (no skill ships): stage → queue →
  `mgr-pick-next` → arm `pod-task-wait` in the background → wake the manager on each worker
  idle → repeat. State in `pod-task.json`; FULL AUTO gates it. See `docs/autonomy.md`.
- **Docked summary pane.** A non-modal black right-edge column (`pod-summary-pane`) with the
  agent roster on top and the newest-first chat feed below. Auto-docks on first attach,
  follows window switches, resizable by dragging the cyan border, scrollable by wheel/keys.
- **pod-watch retired in favor of the docked summary pane.** The dashboard window is gone.
- **Drag-to-reorder.** Drag a tab along the strip, or `M-C`/`M-V` to move the focused window
  left/right (`M-c`/`M-v` cycle). The manager (window 0) is immovable.
- **Human-only gold stars.** `pod-star` + the `⭐` picker (`pod-star-menu`); only the human
  awards. A deliverable agent receives the star as a real prompt on its next idle.
- **Pod rename migration.** Double-click the pod badge or `M-r` to rename; the
  `session-renamed` hook (`pod-sync-pod-name`) migrates the comms subtree, primary record,
  and `@pod_name`.
- **Unread pills.** A direct or `@everyone` `pod-tell` stamps a red unread-count pill on the
  recipient's tab, cleared at its next prompt / idle tick. The quiet `chat` tier reaches
  everyone without badging.
- **State-dot refinement.** `@state_since` drives the summary-pane activity timer; the
  manager `👑` crown shows only under FULL AUTO; a stuck "wait" dot is rescued.
- **New shared sources.** `_pod-strip.sh` (the single source of the status-strip formats) and
  `_mgr-runtime.sh` (the minimal pod-resolution + FULL AUTO gate helpers).

# Changelog

## pod-doctor learns why decks blink

- **`pod-doctor` now runs host/rendering checks**, born from a live Windows debugging
  session. A redraw-heavy deck surfaces host-layer problems as a "blinking" or
  glitching pod, which reads as an agent-pods bug and never is. The doctor now names
  the three observed causes: a WSL checkout on the Windows filesystem (`/mnt` rides
  the 9P mount, which drops exec bits, so hook and strip commands fail on every fire
  — FAIL, with the re-clone fix; the launcher symlink is checked separately so a
  half-healed move is caught too), a legacy-console hint (no Windows Terminal marker
  — WARN, with the caveat that the marker reflects where the server started), and a
  non-UTF-8 locale (wide-glyph width disagreement makes the strip shimmer — WARN).
  A new final section tails the tmux server's message log, because a command that
  fails on every fire flashes the message line over the strip a few hundred
  milliseconds at a time — and THAT, most often, is what "the pod is blinking"
  actually is.

## Baked-effort model ids get a real effort axis

- **`[discover].effort_suffixes` collapses Cursor-style baked ids into families.**
  Cursor encodes reasoning effort INTO the model id (`grok-4.6-low` …
  `grok-4.6-xhigh`), so the picker showed a wall of near-duplicate "models" and an
  empty effort axis. With the new key, discovered ids ending in a declared suffix
  fold into one family per base id whose effort ladder is exactly the rungs
  discovery proved; picking a rung launches the full baked vendor id (there is no
  flag to pass, so `effort_arg` stays empty). The details that keep it honest:
  suffixes match longest-first so `-extra-high` can never be mis-split as base
  `…-extra` + `high`; a discovered bare base id becomes a leading `default` rung;
  a family discovery only ever returned rungs for launches as its first proven rung
  rather than a minted bare id; a collapsed family's ladder wins over a static
  `[[models]]` ladder, which could otherwise assert rungs discovery never returned;
  and an unproven rung is rejected at launch. Ids matching no suffix pass through
  untouched, so `auto` and friends are exactly as before. The bundled cursor
  adapter turns it on; `test/check-effort-collapse.sh` pins the whole matrix with a
  printf-backed fake vendor.

## Workflow-aware state dots, the fresh-crew FULL AUTO reset, and pod-kill

- **A seat that launched a background workflow no longer reads idle mid-run.** Claude
  Code's Workflow tool returns immediately and its agents grind on in the background,
  so the Stop hook stamped the seat green — and a "free" green seat is a legal target
  for auto-dispatch, mail submits, and star delivery — while its workflow was still
  churning. The new `pod-workflow-state` records each launch from the PostToolUse
  payload (a matcher-scoped hook group, so ordinary tool calls pay nothing) and
  `pod-state` now consults it before EVERY idle stamp: Stop, the idle-prompt
  Notification remap, SessionStart, and any idle path added later, by construction.
  Liveness comes from the workflow's own journal — an agent with a `started` and no
  `result` is in flight — with a quiescence grace between phases, a startup grace
  before the journal exists, and a hard TTL so a crash can never pin a seat busy
  forever. A fresh process in the same window provably owns nothing its predecessor
  launched, so SessionStart drops the registry outright. `test/check-workflow-state.sh`
  covers the record/suppress/finish/reset/backstop cycle.

- **A human flip to FULL AUTO now offers the pod as a fresh crew.** An auto-mode
  manager that inherits a half-finished conversation manages around it, and idle seats
  you were merely chatting with are legal dispatch targets — availability filters on
  idle, not on ownership. So a human ON flip confirms first (tmux `confirm-before` on
  the flipping client, or a TTY prompt), clears the manager and every agent seat, and
  delivers a boot brief so the manager greets you and stands by owning the roster.
  The guard that matters: **an agent's own `pod-auto on` never resets** — an
  autonomous loop's first step is flipping this switch, and without the guard a
  manager would clear itself the moment it started. Agent flips are told apart the
  same way pod-star's human-only gate works, and programmatic flips stay
  byte-identical to before. What gets cleared is adapter-scoped through a new
  `lifecycle.clear_cmd` (Claude Code ships `/clear`): no clear command, no typing —
  the seat is skipped and named, and plain shells are never touched. Queued tasks
  survive and are named in the boot brief instead of silently ground through on a
  cleared context. `--yes` / `--reset` / `--no-reset` make every path scriptable, and
  `test/check-fullauto-reset.sh` proves the who-gets-typed-into matrix with capture
  panes.

- **`pod-kill` deliberately ends whole pods.** Closing the terminal window does NOT:
  tmux is a server, so the X only detaches the viewing client while the session, every
  seat REPL in it, and all their MCP subprocesses keep running headless — observed on
  a live deck as two closed-but-unkilled pods idling for two days with 18 seats and
  ~100 MCP processes. Containment over convenience: only `@is_pod`-stamped sessions
  are killable (a shared server's unrelated sessions are never in scope, force or
  not), busy seats and the pod you are running inside need `--force`, and every kill
  is logged to `$POD_STATE/kill.log`. `--list` shows each session's windows, attach,
  busy and pod state.

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
  push/PR workflow now runs nine checks — `check-adapters`, `lint-tmux-targets`,
  `no-private-leaks`, `check-install-modes`, `check-model-policy`,
  `check-context-emit`, `check-primer`, `test-adapter-discovery-timeout`,
  `check-safety-invariants` — on **both**
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

## Operator primer and memory

- **Operator primer.** At each seat's session start, `pod-primer` injects a concise,
  role-gated primer (as `additionalContext`, like the journal): a manager seat gets
  "how to run the pod" (`pod` / `pod-tell` / the `mgr-*` fire-and-poll loop), a worker
  gets the lighter completion contract. Generic primers ship in
  `lib/primer/{manager,worker}.md`; role is the pod's manager window. `POD_PRIMER=0`
  silences it. Wired into both the Claude Code and Codex hook installers.
- **Operator memory.** `pod-remember "<lesson>"` appends to a durable, cross-session
  file (`~/.config/pod/operator-memory.md`) that `pod-primer` injects into every seat
  you spawn afterward — distinct from `pod-note`, which is one pod's ephemeral journal.
- `test/check-primer.sh` covers role selection, memory injection, the `POD_PRIMER=0`
  kill switch, and silence outside a stamped pod.

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

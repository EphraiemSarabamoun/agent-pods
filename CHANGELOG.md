# Changelog

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

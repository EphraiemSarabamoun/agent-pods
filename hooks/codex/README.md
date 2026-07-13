# Codex lifecycle hooks

The Codex CLI fires Claude-style lifecycle hooks from `~/.codex/hooks.json`
(`$CODEX_HOME/hooks.json` if set), which gives Codex full hook parity with Claude
Code: instant state dots on the pod strip, per-turn work headlines, startup pod
awareness, and pod-mail injected silently as context at its next prompt — no
send-keys.

```sh
hooks/codex/install.sh                       # wire into ~/.codex/hooks.json
hooks/codex/install.sh --hooks-file <path>   # or a custom location
hooks/codex/uninstall.sh                     # remove exactly our entries
hooks/codex/uninstall.sh --restore           # or roll back to the newest backup
```

What gets wired (absolute paths into this repo's `bin/`):

| event             | commands |
|-------------------|----------|
| SessionStart      | `pod-codex-state idle` · `pod-awareness.sh codex` |
| UserPromptSubmit  | `pod-codex-state busy user_prompt_submit` · `pod-mail-check UserPromptSubmit` |
| PermissionRequest | `pod-codex-state wait` |
| PostToolUse       | `pod-codex-state busy` |
| Stop              | `pod-codex-state idle stop --json` (Codex requires JSON on Stop stdout) |

`bin/pod-codex-state` is the thin adapter: it maps each event to `pod-state`,
stamps the window as Codex (`@agent_id` / `@pod_native_delivery` / `@state_source`),
captures the `@work` headline on the prompt event, and satisfies the Stop JSON
contract. The awareness hook is shared with the claude-code wiring; the `codex`
argument sets which agent id it stamps.

The installer merges, never clobbers: existing hooks.json entries are preserved,
our entries are appended as their own groups, re-runs are idempotent, and every
rewrite is atomic with a `.pod-bak.<timestamp>` backup alongside. If the optional
`bin/pod-brief` module is present at install time, its boot/refresh entries are
wired too.

Without these hooks Codex still works in a pod as a poll agent (state inferred
from the pane, mail via send-keys) — see `docs/adapters.md` for how the two modes
relate.

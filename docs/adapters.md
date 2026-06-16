# Writing an adapter

An adapter is a single TOML file that teaches agent-pods how to work with one AI coding
agent: how to launch it, how to recognize it running in a tmux pane, what to print on its
identity card, and what models and efforts it offers. Drop a `*.toml` in the catalog and
the agent shows up in the `+` spawn menu, no code change.

Adapters live in two places, and the catalog is the union:

- `adapters/` in the repo: the bundled defaults (`claude-code`, `codex`, `cursor`, `gemini`, `aider`, `opencode`, `openclaw`, `generic-shell`).
- `~/.config/pod/adapters/`: your overrides. Same `[agent].id` as a repo file? Yours wins. New `id`? It's added.

Files whose name begins with `_` (like `_schema.toml`) are documentation and are never
loaded. Nothing parses the TOML directly except `bin/pod-adapter`; every other script
asks `pod-adapter` for what it needs (`pod-adapter list`, `pod-adapter launch <id> ...`,
`pod-adapter card <id> ...`, `pod-adapter models <id>`, and so on). That keeps the format
in one place and lets you add an agent without editing any shell or python.

## The schema, field by field

The canonical template is `adapters/_schema.toml`. Here is what every section does.

### `[agent]`

```toml
[agent]
id       = "example"          # stable key; cached on the window as @agent_id
label    = "Example Agent"    # pretty name shown in cards and menus
priority = 50                 # detection tie-break, LOWER wins; generic-shell = 9999
```

`id` is the handle you pass to `pod-add-worker --agent <id>` and the key the window
remembers. `label` is the human name on the strip card and in the `+` menu. `priority`
only matters for detection (below): when more than one adapter could claim a pane, the
lowest number wins.

### `[launch]`

```toml
[launch]
base_cmd   = "example"                  # the binary (resolved on PATH); or a ${SHELL}-style expansion
model_arg  = ["--model", "{model}"]     # argv tokens; {model} <- the chosen model's `model` value
effort_arg = ["--effort", "{effort}"]   # argv tokens; {effort} <- the chosen effort's `value`
```

The launch command is built by templating:

```
launch = base_cmd  + model_arg (if a model is picked, with {model} filled in)
                    + effort_arg (if an effort is picked, with {effort} filled in)
```

Each token is a **separate argv word**, and the spawn path word-splits on spaces to
rebuild argv. So keep every token space-free. If your agent's model flag and value are
one token (`-c model_reasoning_effort={effort}`, as Codex does for effort), that's fine,
since it's one space-free token. If an arg would need a space, model it as two tokens.

`base_cmd` is normally a bare binary name resolved on `PATH` (`claude`, `codex`,
`aider`). It can also be a shell expansion that the spawn evaluates rather than
`pod-adapter`. `generic-shell` uses `"${SHELL:-/bin/bash}"` so a shell worker always
launches whatever the user's shell is.

### `[detect]`

```toml
[detect]
pane_cmd_patterns = ['^example$']   # regex vs #{pane_current_command} (cheap, tried first)
content_patterns  = []              # regex vs capture-pane output (fallback; for node/python TUIs)
reject_content    = []              # if any matches the pane content, do NOT claim it (veto)
```

This is how `pod-detect` figures out which agent is running in a window it didn't launch
(a pane you opened by hand, or after a restart). It is also why the catalog has a single
detection authority: `pod`, `pod-tell`, `pod-deliver`, and the foreign-state poller all
read the cached `@agent_id` that detection wrote, never re-test the pane themselves.

**Detection priority.** `pod-adapter detect` walks adapters in ascending `priority`. For
each, it first checks `reject_content` (any match vetoes the claim), then tries
`pane_cmd_patterns` against the pane's current command, then `content_patterns` against
the captured pane text. The first adapter that matches wins. `generic-shell` sits at
priority 9999 with `pane_cmd_patterns = ['.*']`, so it is the last-resort claim that
catches every otherwise-unclaimed pane.

The split between the two pattern lists matters for cost. A command like `claude` reports
a unique foreground command, so a `pane_cmd_patterns` match is enough and no pane capture
is needed; the common case stays a single tmux round-trip. But Node-based TUIs all
report `node` as the pane command (Codex, Cursor, Gemini, OpenCode can all be `node`), so
those adapters list `node` in `pane_cmd_patterns` *and* a `content_patterns` regex
(`'(?i)codex'`) that confirms which one it actually is by scraping the visible text.

### `[defaults]`

```toml
[defaults]
model             = "default"   # used when the manager seat / a bare spawn picks this agent
effort            = ""
card_scrape_regex = ''          # optional: read live model/effort from the pane footer
```

`model` and `effort` are what a spawn uses when you don't pick one.

`card_scrape_regex` is for poll agents whose model/effort can change inside the running
TUI (you switch models in Codex mid-session). The foreign-state poller runs this regex
against the bottom of the pane and, if it matches, rewrites the strip card live. **Group
1 must capture the model, group 2 the effort.** Codex's is a good example:

```toml
card_scrape_regex = '^\s*([A-Za-z][\w.\-]*\d[\w.\-]*)\s+(minimal|low|medium|high|xhigh|max|none)\b.*·'
```

Leave it empty (`''`) if the agent has no model/effort to scrape, or if its card is set
authoritatively another way (Claude Code stamps its card from a hook, so its scrape regex
is empty).

### `[lifecycle]`

```toml
[lifecycle]
mode            = "poll"   # "hooks" = agent fires lifecycle events we wired; "poll" = the floor
installer       = ""       # repo-relative path to a hook installer; only for mode="hooks"
native_delivery = false    # true = agent surfaces pod-mail itself -> pod-deliver skips send-keys
state_source    = "poll"   # "hooks" = agent stamps its own @cc_state; "poll" = the poller infers it
```

This is the hooks-vs-poll distinction, the heart of "generic is first-class, hooks are an
upgrade."

- **`mode = "poll"`** (the floor, and what every adapter except Claude Code uses): the
  agent has no lifecycle integration. agent-pods infers its state by watching the pane,
  and delivers pod-mail by typing a notification into the pane when it's idle. This works
  for any TUI with zero cooperation from the agent.

- **`mode = "hooks"`**: the agent can run commands at lifecycle events (turn start, turn
  end, session start, permission prompt), and `installer` points at a script that wires
  those events to agent-pods' `pod-state` / `pod-mail-check` / `pod-work` helpers. With
  hooks, state dots flip instantly (no poll lag), work headlines are captured per turn,
  and the agent learns about new pod-mail as context at its next turn.

`state_source` mirrors `mode` for the state dot specifically: `"hooks"` means the agent
stamps its own `@cc_state` and the poller leaves it alone; `"poll"` means the poller owns
the dot.

`native_delivery` controls pod-mail. When `true`, the agent surfaces its own mailbox
(via its `pod-mail-check` hook emitting `additionalContext`), so `pod-deliver` must NOT
type into its pane, since that would double-deliver and risk clobbering the agent's input.
When `false` (every poll agent), `pod-deliver` is the only delivery path and it uses
send-keys. The detector caches this as `@pod_native_delivery` on the window; a
hook-capable agent's own hook re-stamps it authoritatively once it's live.

### `[[models]]`

Zero or more model tables. Each has a `slug` (the short key the menu and CLI use), a
`label` (what's shown), the `model` value substituted into `{model}`, and an inline array
of `efforts` (which may be empty).

```toml
[[models]]
slug   = "opus"
label  = "Opus 4.8"
model  = "claude-opus-4-8"
efforts = [
  { slug = "high",   label = "high",   value = "high" },
  { slug = "low",    label = "low",    value = "low" },
]
```

An agent with no model/effort to pick (a shell) simply omits `[[models]]`.

### `[discover]` (optional) — live models

Hand-typed `[[models]]` lists drift the moment an agent ships a new model. If the
agent's CLI can enumerate what it serves, add a `[discover]` block and the picker
reads reality instead. When the command succeeds, its parsed models **replace**
`[[models]]` (which then serves only as the offline fallback, and as a source of
prettier labels / effort ladders matched by slug).

```toml
[discover]
models_cmd   = "cursor-agent --list-models"          # any shell command
models_regex = '^(\S+)\s+-\s+(.+?)(?:\s+\(current\))?$'  # grp1 = id, grp2 = label
timeout_s    = 8                                      # kill discovery after N seconds
ttl_s        = 21600                                  # cache the result for 6h
efforts      = []                                     # ladder applied to every model
```

`models_cmd` runs through the shell, so it can reach a remote backend
(`"ssh gpu-box ollama list"`). Each stdout line is matched by `models_regex`: group 1
is the model id (used as both the `{model}` value and the slug), an optional group 2
is the pretty label, and non-matching lines (headers, blanks) are skipped. Only models
are discovered — effort ladders aren't enumerable from any CLI, so `[discover].efforts`
declares the ladder applied to every discovered model (empty = no effort axis; cursor,
for instance, bakes effort into the model slug). Results cache under
`$POD_STATE/discover/<id>.json`; `pod-adapter refresh [id]` busts the cache and
re-queries.

#### Discovery via an authenticated API (`auth` + `pod-login`)

Some agents — Claude Code, Codex — have no `--list-models` command at all, but the
*provider's* REST API does (`GET /v1/models`). For those, point `models_cmd` at the
bundled `pod-discover-api` helper and name the provider with `auth`:

```toml
[discover]
auth         = "anthropic"                  # or "openai"
models_cmd   = "pod-discover-api anthropic" # calls GET /v1/models with a key
models_regex = '^(\S+)\s+-\s+(.+)$'
efforts = [ { slug = "high", label = "high", value = "high" }, ... ]
```

`pod-discover-api` resolves a key without bothering the user when it can — the
provider env var (`ANTHROPIC_API_KEY` / `OPENAI_API_KEY`), a key the CLI itself stored
(`~/.codex/auth.json`, or a Claude Code API-key login), or one captured by `pod-login`.
A plain **subscription** login (Claude Pro/Max, ChatGPT) stores a short-lived OAuth
token that does *not* authenticate against `/v1/models`, so for those users discovery
fails and the curated `[[models]]` is used instead — which is the right model list for
a subscription anyway.

`pod-login [agent]` is the front door: it reads `auth` to know which provider to ask
for, reuses an existing key if one is resolvable, otherwise points you at the provider's
key page, reads a key without echoing it, **validates it with a live call**, and stores
it at `~/.config/pod/keys/<provider>` (chmod 600). `install.sh` offers this during
setup (skippable; `--with-logins` / `--no-logins` to answer non-interactively). Effort
levels still aren't served by any API, so they stay declared in `[discover].efforts`.

## Three worked examples

### claude-code, full hooks

```toml
[agent]
id = "claude-code"
label = "Claude Code"
priority = 10

[launch]
base_cmd   = "claude"
model_arg  = ["--model", "{model}"]
effort_arg = ["--effort", "{effort}"]

[lifecycle]
mode            = "hooks"
installer       = "hooks/claude-code/install.sh"
native_delivery = true
state_source    = "hooks"
```

Detection is trivial: Claude Code reports its version string (`2.1.158`) as the pane
command, so `pane_cmd_patterns = ['^[0-9]+\.[0-9]+']` is unambiguous and needs no content
scrape. Because `mode = "hooks"`, the installer wires SessionStart / UserPromptSubmit /
Stop / Notification to `pod-state`, `pod-mail-check`, `pod-work`. Because
`native_delivery = true`, pod-mail reaches it as additionalContext, never as send-keys.

### codex, poll with a scraped card

```toml
[agent]
id = "codex"
label = "Codex"
priority = 20

[launch]
base_cmd   = "codex"
model_arg  = ["-m", "{model}"]
effort_arg = ["-c", "model_reasoning_effort={effort}"]

[detect]
pane_cmd_patterns = ['^node$']
content_patterns  = ['(?i)codex', 'model_reasoning_effort']

[defaults]
card_scrape_regex = '^\s*([A-Za-z][\w.\-]*\d[\w.\-]*)\s+(minimal|low|medium|high|xhigh|max|none)\b.*·'

[lifecycle]
mode            = "poll"
native_delivery = false
state_source    = "poll"
```

Codex is a Node TUI, so the pane command is `node`, which is ambiguous. The
`content_patterns` disambiguate it. It has no hooks, so its state dot comes from the
poller and its card comes from `card_scrape_regex` (the footer reads `gpt-5.5 high · ~`;
group 1 = model, group 2 = effort). pod-mail reaches it via a send-keys notification.

### generic-shell, the universal floor

```toml
[agent]
id = "generic-shell"
label = "Shell"
priority = 9999

[launch]
base_cmd   = "${SHELL:-/bin/bash}"
model_arg  = []
effort_arg = []

[detect]
pane_cmd_patterns = ['.*']

[lifecycle]
mode            = "poll"
native_delivery = false
state_source    = "poll"
# no [[models]]: a shell has no model/effort
```

This is the catch-all: priority 9999 and a `.*` command pattern, so any pane no other
adapter claims is still a first-class podmate with a roster entry, a color, a poll-based
state dot, and pod-mail. It's also the default manager seat and the default bare worker.
This is what makes agent-pods work with no AI agent installed at all.

## User overrides

Anything you put in `~/.config/pod/adapters/` is loaded after the repo defaults. To
adjust a bundled agent (different models, a different binary path), copy its file there
and edit your copy, keeping the same `id` so your version wins. To add an agent the repo
doesn't know, drop a new `*.toml` with a new `id`. Either way it appears in the `+` menu
on the next spawn, because the menu is built from `pod-adapter list`. No reinstall, no
code change.

Confirm what the catalog resolved to:

```sh
pod-adapter list                          # every known agent id
pod-adapter list --available              # only those whose base_cmd is on PATH
pod-adapter card claude-code --model opus --effort high
pod-adapter launch codex --model gpt-5.5 --effort high
pod-adapter dump --json                   # the whole resolved catalog (debug)
```

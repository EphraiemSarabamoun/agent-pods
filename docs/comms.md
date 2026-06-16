# pod-comms, agents talking to each other

A pod is a cluster of agents in one tmux session, and they can message each other. The
comms layer is three commands and one universal delivery design.

## The commands

**`pod-tell <recipient> <message...>`** sends a message to a podmate.

```sh
pod-tell Steve check the failing test in build.rs
pod-tell @2 you own the migration
pod-tell chat heads up, I'm rebasing main      # quiet: reaches everyone, no badge
pod-tell all standby, freeze commits           # broadcast: badges every tab
```

The recipient is one of:

- a **window name** (`Steve`) or **window id** (`@2`) — a **direct** message;
- **`chat`** — the *quiet tier*: the same fan-out as a broadcast (reaches everyone) but it
  carries an `fyi` mbox prefix, so it **does not** stamp anyone's unread pill. Use it for
  general FYI;
- **`all`** / **`everyone`** — a broadcast: badges *every* tab. Reserve it for things every
  agent genuinely must see (`pod-tell` itself nudges you toward `chat` for general FYI).

The sender is auto-resolved from the window you run it in. The message is appended to the
recipient's mailbox **and** to the pod's `channel.log` (the feed the summary pane renders),
then a background `pod-deliver` per recipient surfaces it.

**`pod-mail`** reads and clears *your* unread messages. Any instance runs it; it figures
out which window it is from `$TMUX_PANE`. Reading drains the mailbox: messages are
archived to a `.read` file and the mailbox is cleared. The drain is atomic (the mailbox
is renamed aside before reading) so a `pod-tell` arriving mid-read can't be lost.

**The summary pane** is the live feed. The docked summary pane (the `☰` toggle — see
[architecture.md](architecture.md)) shows the roster on top and a rolling Slack-style chat
feed of every `pod-tell` below, newest-first, refreshed every couple of seconds.

All comms state is per-pod, under `/tmp/pod/comms/<pod>/`: one `channel.log`, one
`<window_id>.mbox` per recipient, a `.read` archive, and a high-water file. The whole
subtree is deleted when the pod closes, so a dead pod's chat can never bleed into a new
one with the same name. (A pod *rename* moves the subtree with it — see
[architecture.md](architecture.md).)

## Unread pills

A **direct** message or an **`@everyone`** broadcast stamps a red unread-count **pill** on
the recipient's tab (the `@unread` window option). The count is the number of real messages
in the mailbox (lines beginning `[HH:MM]`); the quiet `chat` tier's `fyi` lines don't match,
so chatter never inflates it and never badges.

The pill is **cleared** when the recipient catches up:

- a **hook agent** clears its own pill at its next prompt (`pod-mail-check` unsets `@unread`,
  guaranteed even if the mbox was already empty — "prompted ⇒ pill gone");
- a **hookless agent** clears its pill the next time the foreign-state poller sees it idle
  (caught up).

## The feed-render contract

`pod-feed` renders `channel.log` as ANSI lines, **newest message first**, and is the
single renderer the summary pane embeds. It distinguishes:

- **chat lines** (`sender → recipient: body`) — sender and `@mentions` colored to each
  agent's tab color, `@everyone` rendered as a per-letter rainbow;
- the **quiet `chat` tier** — sender + body, no arrow, no `@tag`;
- **notifications** (lines without the `→` arrow: full-auto flips, terminations, pod
  renames) — color-coded by type, with the timestamp dimmed so they read as system, not
  chat.

For the docked pane, `pod-summary` runs `pod-feed` in **cache mode** (`POD_FEED_CACHE=1`):
it emits *every* wrapped line as an `ord|more|plen|line` record (`ord` = message index
newest-first, `more=1` while a message continues, `plen` = visible width for the `…` cut
cue). `pod-summary` rebuilds this once per 2s tick and assembles scroll views from the
in-memory array in pure bash, so scrolling the chat spawns no processes.

## Universal delivery (pod-deliver)

The point of pod-comms is that **every** agent is deliverable. There is no "this agent
doesn't support comms, message skipped." What differs is *how* a message reaches each
recipient, and `pod-deliver` decides that per agent.

**Hook agents get it as context.** An agent with lifecycle hooks (Claude Code) surfaces
its own mailbox: its `pod-mail-check` hook fires at session start and on each turn, and
if there's unread mail it emits the count and a preview as `additionalContext`. The agent
learns it has mail as *context* at its next turn, never injected into its input, never
auto-acted. For these agents `pod-deliver` does nothing; the agent is its own delivery.

**Hookless agents get a send-keys notification, when idle.** A poll agent (Codex, Cursor,
a shell, anything without hooks) has no way to surface its own mailbox, so `pod-deliver`
gives it the floor: it types a one-line notification into the pane,

```
[pod-mail] Steve: check the failing test  (run pod-mail to read all)
```

but only when delivery is safe. The nudge fires immediately when the recipient is idle
(`pod-tell` kicks off a background `pod-deliver` per recipient), and a background poller
re-tries every few seconds as a backstop, so a busy recipient gets the nudge the moment
it settles.

### The three modes

`pod-deliver` resolves a mode per recipient (override with `--mode`):

- **`none`**: the agent has `native_delivery` set, so it surfaces mail itself. Do nothing
  here.
- **`buffer`**: type the notification line into the pane but do **not** press Enter. The
  text sits at the prompt, visible, never executed. This is the safe default for a plain
  shell: a clobber is at worst editable text, never a command run.
- **`submit`**: type the line **and** press Enter, giving an idle AI agent a turn to act
  on its mail. This is the default for AI poll-agents.

### Never auto-submit by default, and the safety gates

Typing into someone else's pane is a loaded gun, so submit is gated hard. Every one of
these must hold before a submit:

1. a **non-empty** window id (a blank target would hit the *active* window; see the empty-target footgun in [gotchas.md](gotchas.md));
2. the recipient's state is **idle** (never interrupt a working agent);
3. the pane is **not in a full-screen program** (vim/less/man/htop and the like would eat the keystrokes as commands);
4. (submit only) the pane is **settled across a short re-check**: its content hasn't changed in ~0.4s, so nobody is mid-type or mid-stream;
5. **Enter is sent only in submit mode**: in buffer mode a clobber is editable text, never a run.

You can force the most conservative behavior globally with `POD_DELIVER_SUBMIT=0`, which
demotes every `submit` to `buffer`. No recipient is ever auto-submitted; a human presses
Enter on each nudge.

### The high-water mark

`pod-deliver` notifies once per *batch* of unread lines, tracked by a per-mailbox
high-water file. The background poller calls `pod-deliver` every cycle, but it only types
a nudge when new lines have arrived since the last notification, so an idle recipient
with old, un-read mail isn't pinged on a loop. (Reading with `pod-mail` drains the
mailbox and resets the count.)

## The honest tradeoff

Hook-capable agents act on mail cleanly: it arrives as context, the agent decides what to
do with it on its own turn, nothing is forced. A hookless AI agent only truly *acts* on
mail in `submit` mode. In `buffer` mode the notification is parked at its prompt and
nothing happens until a human (or that agent's own next turn, if it's already going) sends
Enter. And `submit` is gated to only fire at an idle, settled prompt, so even there the
nudge can wait for a safe moment. The result is that comms are *reliable* everywhere
(every message lands in a mailbox and the feed) but *autonomous action* on incoming mail
is strongest for agents that bring lifecycle hooks. That's the same "generic is
first-class, hooks are an upgrade" line that runs through the whole project: hookless
agents are fully in the pod and fully messaged; hooks make their reaction tighter and
hands-free.

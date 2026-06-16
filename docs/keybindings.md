# Keybindings

A pod is mouse-first — every status-strip button is clickable — but every action also
has a keyboard chord. There are two chord families:

- the **`C-a` prefix table** (press `C-a`, release, then the key), and
- the **`M-` root table** (Meta/Option held with the key, no prefix).

`C-a` is the pod prefix (screen-style), moved off the tmux default so bare `C-b` is free
to cycle windows. The button actions in both tables route through the *same* backend as
the mouse buttons (`pod-status-action`), so a click and its chord are one code path.

## Option-as-Meta (required for the `M-` table on macOS)

The `M-` chords send a Meta modifier. On macOS, **Terminal.app and iTerm2 do not send
Meta by default** — you must turn it on, or the `M-` table does nothing (the key lands as
a plain character):

- **Terminal.app:** Settings → Profiles → Keyboard → check **"Use Option as Meta key."**
- **iTerm2:** Settings → Profiles → Keys → set the **Left Option key** (and/or Right) to
  **Esc+.**

Without this, use the `C-a` prefix table instead — it needs no terminal setting.

## The `C-a` prefix table

Press `C-a`, release, then the key.

| Chord | Action |
| --- | --- |
| `C-a C-a` | send a literal `C-a` to the focused pane (`send-prefix`) |
| `C-a a` | toggle this pod's **FULL AUTO** switch (`⚡ AUTO` / `✋ MAN`) |
| `C-a s` | toggle the docked **summary pane** (`☰`) |
| `C-a +` | open the **spawn** agent/model picker (`+`) |
| `C-a g` | open the **settings** slot editor (`⚙`) |
| `C-a *` | open the gold-**star** picker (then a digit jumps to that tab) |
| `C-a X` | terminate (kill) the **focused** worker (window 0 refused) |
| `C-a ,` | rename the focused worker (tmux-native; syncs the registry) |

(`C-a $` is tmux-native rename-session, and `C-a w` is the tmux choose-tree window
chooser — both still available since `C-a s` was reassigned to the summary toggle.)

## The `M-` root table

Hold Meta/Option with the key (no prefix). See Option-as-Meta above.

| Chord | Action |
| --- | --- |
| `M-a` | toggle **FULL AUTO** |
| `M-s` | toggle the docked **summary pane** |
| `M-d` | open the **spawn** picker (`+`) |
| `M-f` | open the **settings** slot editor (`⚙`) |
| `M-g` / `M-*` | open the gold-**star** picker |
| `M-x` | terminate the **focused** worker |
| `M-r` | **rename** this pod (the `session-renamed` hook migrates its comms behind it) |
| `M-c` / `M-v` | **cycle** to the previous / next window (focus only, no move) |
| `M-C` / `M-V` | **move** the focused window left / right (reorder; manager immovable) |

`M-C`/`M-V` are the shifted twins of the cycle chords — deliberately not `M-←`/`M-→`,
which would steal Option+arrow word-jump in the shell.

## Bare keys (no chord)

| Key | Action |
| --- | --- |
| `C-b` | next window (cycle the pod) |

## Mouse map

Mouse is on by default. Clicks on the status strip:

| Click | Action |
| --- | --- |
| click a **tab** | select that window |
| click the **`✕`** on a tab | terminate that worker (confirm prompt; absent on window 0) |
| **drag** a tab along the strip | reorder it (swap with the tab under the pointer) |
| **double-click** a tab | rename that worker |
| **double-click** the pod **badge** (status-left) | rename the pod |

The button row at the right of the strip (`status-right`), left to right:

| Button | Action |
| --- | --- |
| `⚡ AUTO` / `✋ MAN` | toggle FULL AUTO |
| `⭐` | open the gold-star picker |
| `☰` | toggle the docked summary pane |
| `+` | open the spawn agent/model picker |
| `⚙` | open the settings slot editor |

## Summary-pane keys

When you click *into* the docked summary pane it becomes interactive (see
[architecture.md](architecture.md)):

| Key | Action |
| --- | --- |
| `j` / `k` or arrows | move the card cursor (popup mode) / scroll the chat (pane mode) |
| digit | jump the cursor to that window index |
| `⏎` / `o` | open (switch to) the selected agent's window |
| `x` | terminate the selected worker (inline `y/n`; window 0 refused) |
| wheel / `u` / `d` | scroll the chat feed (`u` page older, `d` page newer) |
| `r` | refresh / jump back to live |
| `q` | close the sidebar (undock + unhook) |

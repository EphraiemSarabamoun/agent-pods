"""
pod-manager — MCP server for the agent-pods manager-worker protocol.

Wraps the mgr-* shell helpers (the optional queue module) and adds observability
tools (window peeking, template discovery, structured returns) that the bare shell
surface doesn't expose. This is the integration surface for MCP-capable agents: a
manager agent calls these tools instead of shelling into mgr-* for every step.

Tmux-only. Workers are colored sibling windows in the active pod (the same deck the
"+" button spawns into) — addressed by stable tmux window id (@N).

First call should be pod_init() to bootstrap the inbox + state trees.
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

# --- Paths ---
#
# Everything resolves from POD_* env (set by _pod-paths.sh / ~/.config/pod/config.sh),
# with repo-relative fallbacks so the server is runnable standalone. Nothing here is
# host-, user-, or persona-specific.

# This module is checkout-bound because it is a thin wrapper around the repository's
# shell runtime. POD_REPO can point at another checkout; otherwise resolve this file's
# <repo>/modules/mcp location directly.
REPO_ROOT = Path(os.environ.get("POD_REPO") or Path(__file__).resolve().parents[2])
POD_MODULES = Path(os.environ.get("POD_MODULES") or (REPO_ROOT / "modules"))
POD_BIN = Path(os.environ.get("POD_BIN") or (REPO_ROOT / "bin"))

# The optional queue module ships the mgr-* helpers and the default templates.
MGR_BIN = POD_MODULES / "queue" / "bin"
REPO_TEMPLATES = POD_MODULES / "queue" / "templates"


def _bash_bin() -> str:
    """bash, explicitly — never $SHELL, never /bin/sh.

    The pod shell layer IS bash (`${BASH_SOURCE[0]}`, arrays, `local`): dash rejects it
    with "Bad substitution" and csh/tcsh never parse it at all. $SHELL is the user's
    login shell, which is none of our business.
    """
    return shutil.which("bash") or "/bin/bash"


def _shell_runtime_paths() -> dict[str, str]:
    """Ask bin/_pod-paths.sh where the runtime tree is instead of re-deriving it.

    That file is the ONE place the tree is resolved: it applies the default, then
    sources ~/.config/pod/config.sh, which is exactly where a user relocates POD_TMP
    (config/config.sh.example documents the knob). A Python re-derivation cannot see
    that file, so the server built a second, permanently empty inbox/state tree while
    every mgr-* helper wrote into the configured one — pod_stage returning a
    prompt_path that does not exist, pod_read_prompt answering "no prompt.txt", and
    every tool still reporting ok. Delegating also inherits future changes to the
    default for free (it moved off $TMPDIR precisely because a per-command TMPDIR
    forked one pod into two trees).

    Resolved once per process: config is startup state, and every other consumer of
    this file pays the same one-time read.
    """
    paths_sh = POD_BIN / "_pod-paths.sh"
    if not paths_sh.exists():
        return {}
    # NUL-separated so a path containing whitespace (or, absurdly, a newline) survives.
    script = (
        '. "$1" >/dev/null || exit 1; '
        'printf "%s\\0" "$POD_TMP" "$POD_STATE" "$POD_INBOX" "$POD_COMMS" "$POD_TMUX"'
    )
    try:
        proc = subprocess.run(
            [_bash_bin(), "-c", script, "pod-paths", str(paths_sh)],
            capture_output=True, text=True, timeout=20, check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if proc.returncode != 0:
        return {}
    keys = ("POD_TMP", "POD_STATE", "POD_INBOX", "POD_COMMS", "POD_TMUX")
    values = proc.stdout.split("\0")
    if len(values) < len(keys):
        return {}
    return {key: value for key, value in zip(keys, values) if value}


_SHELL_PATHS = _shell_runtime_paths()


def _runtime_path(var: str, fallback: Path) -> Path:
    """Shell answer first (it already folded in env AND config.sh), env second (only
    reachable when the shell layer is missing), repo default last."""
    return Path(_SHELL_PATHS.get(var) or os.environ.get(var) or fallback)


# One state/inbox tree under POD_INBOX / POD_STATE. The fallbacks below only fire when
# _pod-paths.sh is unavailable; KEEP THEM IN SYNC with it — notably a FIXED /tmp root,
# never $TMPDIR, because TMPDIR is per-context (GUI terminal vs ssh vs a sandbox that
# hands every command its own) and a TMPDIR-derived root splits one pod in two.
_RUNTIME_ROOT = _runtime_path("POD_TMP", Path(f"/tmp/agent-pods-{os.getuid()}"))
INBOX_ROOT = _runtime_path("POD_INBOX", _RUNTIME_ROOT / "inbox")
STATE_DIR = _runtime_path("POD_STATE", _RUNTIME_ROOT / "state")
COMMS_DIR = _runtime_path("POD_COMMS", _RUNTIME_ROOT / "comms")
QUEUE_DIR = INBOX_ROOT / "_queue"  # per-pod children live below this root
TEMPLATES_DIR = INBOX_ROOT / "_templates"
DISPATCHED_DIR = STATE_DIR / "dispatched"  # per-pod children live below this root
COMPLETED_DIR = STATE_DIR / "completed"

CONFIG_PATH = STATE_DIR / "inbox-config.json"
WORKERS_PATH = STATE_DIR / "workers.json"
LOG_PATH = STATE_DIR / "log.jsonl"
REGISTRY_PATH = TEMPLATES_DIR / "_registry.json"

# The pod launcher (used only for an existence sanity-check before spawning).
POD_LAUNCHER = POD_BIN / "pod-launch"
TMUX_GROUP_PATH = STATE_DIR / "tmux_group.json"

# The color palette — SINGLE SOURCE shared with bin/pod-add-worker (lib/palette).
PALETTE_PATH = Path(os.environ.get("POD_PALETTE") or (REPO_ROOT / "lib" / "palette"))

# The adapter is the only catalog reader; we shell out to it for cards/launch/fields.
POD_ADAPTER = os.environ.get("POD_ADAPTER") or str(POD_BIN / "pod-adapter")

# --- Logging ---

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("pod-manager")

# --- MCP server ---

mcp = FastMCP("pod-manager")


# --- Helpers ---


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _host_short() -> str:
    if hasattr(os, "uname"):
        return os.uname().nodename.split(".")[0]
    return "localhost"


def _child_env() -> dict[str, str]:
    """Environment for every helper we shell out to, with the runtime tree PINNED.

    A child re-derives POD_TMP from its own environment, so anything that changes
    between our startup and the call — a sandbox handing each command a fresh TMPDIR,
    a config.sh edit — is enough to send parent and child to different trees while both
    report success. Passing the four roots we already resolved makes that impossible.
    POD_TMUX rides along for the same reason: agent-pods runs on a dedicated tmux
    socket by default, and a child that resolves a bare `tmux` would talk to the user's
    server instead of the deck we are looking at.
    """
    env = dict(os.environ)
    env["POD_TMP"] = str(_RUNTIME_ROOT)
    env["POD_STATE"] = str(STATE_DIR)
    env["POD_INBOX"] = str(INBOX_ROOT)
    env["POD_COMMS"] = str(COMMS_DIR)
    env["POD_TMUX"] = _tmux_bin()
    return env


def _mgr_query(snippet: str, count: int, args: list[str] | None = None) -> list[str]:
    """Run one _mgr-runtime.sh helper in a subshell and return its NUL-separated fields.

    This is how the server asks the shell layer a question it must not answer itself
    (which pod am I in, is FULL AUTO on). Same reasoning as _shell_runtime_paths:
    reimplementing the rule in Python is what let the two sides drift apart. Returns []
    on any failure so callers can fall back rather than crash.
    """
    paths_sh = POD_BIN / "_pod-paths.sh"
    runtime_sh = POD_BIN / "_mgr-runtime.sh"
    if not paths_sh.exists() or not runtime_sh.exists():
        return []
    # _pod-paths.sh EXPLICITLY first: _mgr-runtime.sh only sources it when POD_TMUX is
    # unset, and _child_env pins POD_TMUX — so leaving it implicit gave us a runtime
    # with mgr_current_pod defined but pod_json_get and POD_SESSION_PREFIX missing, and
    # the helper answered the empty string instead of the pod name.
    script = f'. "$1" >/dev/null || exit 1; . "$2" >/dev/null || exit 1; {snippet}'
    try:
        proc = subprocess.run(
            [_bash_bin(), "-c", script, "mgr-runtime", str(paths_sh), str(runtime_sh),
             *(args or [])],
            capture_output=True, text=True, timeout=20, check=False, env=_child_env(),
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []
    fields = proc.stdout.split("\0")
    return fields[:count] if len(fields) > count else []


def _run_mgr(script: str, args: list[str], check: bool = True) -> dict[str, Any]:
    """Invoke a mgr-* helper (from the queue module). Returns {stdout, stderr, returncode}."""
    cmd = [str(MGR_BIN / script), *args]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=_child_env())
    result = {
        "command": " ".join(cmd),
        "stdout": proc.stdout.strip(),
        "stderr": proc.stderr.strip(),
        "returncode": proc.returncode,
    }
    if check and proc.returncode != 0:
        result["error"] = f"{script} exited {proc.returncode}: {proc.stderr.strip()}"
    return result


def _read_json(path: Path, default: Any = None) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        return {"_error": f"invalid JSON at {path}: {e}"}


def _write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(data, out, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _mutate_workers(mutator: Any) -> Any:
    """Serialize every MCP workers.json read-modify-write with the CLI lock."""
    WORKERS_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(str(WORKERS_PATH) + ".lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            data = _read_json(WORKERS_PATH, {"workers": []})
            if not isinstance(data, dict) or "_error" in data:
                detail = data.get("_error") if isinstance(data, dict) else "root is not an object"
                return {"error": f"workers registry is unreadable: {detail}"}
            if not isinstance(data.get("workers"), list):
                return {"error": "workers registry has no workers array"}
            if any(not isinstance(worker, dict) for worker in data["workers"]):
                return {"error": "workers registry contains a non-object row"}
            result = mutator(data["workers"])
            if isinstance(result, dict) and "error" in result:
                return result
            _write_json(WORKERS_PATH, data)
            return result
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


_SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def _valid_component(value: str | None) -> bool:
    return bool(value and value not in {".", ".."} and _SAFE_COMPONENT.fullmatch(value))


def _runtime_layout_error(create: bool = False) -> str | None:
    """Mirror _pod-paths.sh's private descendant/ownership contract."""
    root = _RUNTIME_ROOT.expanduser()
    if str(root) in {"", "/", str(Path.home())}:
        return f"refusing broad runtime root: {root}"
    if root.is_symlink():
        return f"refusing symlink runtime root: {root}"
    try:
        if create:
            root.mkdir(parents=True, mode=0o700, exist_ok=True)
        if not root.exists():
            return None
        root_real = root.resolve()
        if root.stat().st_uid != os.getuid():
            return f"runtime root is not owned by uid {os.getuid()}: {root}"
        for child in (INBOX_ROOT, STATE_DIR):
            if child.is_symlink():
                return f"refusing symlink runtime directory: {child}"
            if create:
                child.mkdir(parents=True, mode=0o700, exist_ok=True)
            if not child.exists():
                continue
            try:
                child.resolve().relative_to(root_real)
            except ValueError:
                return f"runtime directory must live below {root_real}: {child.resolve()}"
            if child.stat().st_uid != os.getuid():
                return f"runtime directory is not owned by uid {os.getuid()}: {child}"
        if create:
            for directory in (root, INBOX_ROOT, STATE_DIR):
                os.chmod(directory, 0o700)
    except OSError as exc:
        return f"cannot prepare runtime layout: {exc}"
    return None


def _ensure_initialized() -> dict[str, Any] | None:
    """Return an error dict if the inbox isn't initialized; None if ready."""
    layout_error = _runtime_layout_error()
    if layout_error:
        return {"error": layout_error}
    if not CONFIG_PATH.exists():
        return {
            "error": "pod manager not initialized",
            "hint": f"call pod_init() first to bootstrap {INBOX_ROOT}/ and {STATE_DIR}/",
        }
    return None


def _elapsed_seconds(iso_ts: str | None) -> int | None:
    if not iso_ts:
        return None
    try:
        started = datetime.strptime(iso_ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
        return int((datetime.now(timezone.utc) - started).total_seconds())
    except Exception:
        return None


# --- tmux grouped-worker helpers ---


def _load_palette() -> list[tuple[str, str]]:
    """Read lib/palette into [(name, code), ...]. SINGLE SOURCE shared with
    bin/pod-add-worker — never re-list the colors inline, or the two spawn paths
    (the "+" button and this MCP) drift. Each non-comment line is "<code> <name>".
    Falls back to a minimal dark set if the file is missing.
    """
    out: list[tuple[str, str]] = []
    try:
        for raw in PALETTE_PATH.read_text().splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                code, name = parts[0], parts[1]
                out.append((name, code))
    except Exception:
        pass
    if not out:
        out = [("ocean", "colour18"), ("maroon", "colour52"),
               ("forest", "colour22"), ("olive", "colour58")]
    return out


def _tmux_bin() -> str:
    grp = _read_json(TMUX_GROUP_PATH, {}) or {}
    if isinstance(grp, dict) and grp.get("tmux_bin"):
        return grp["tmux_bin"]
    # _SHELL_PATHS' POD_TMUX before a bare `tmux`: agent-pods runs on its own tmux
    # socket by default (via the shim _pod-paths.sh writes), so resolving the plain
    # binary here would point every call at the user's default server — a deck that
    # looks empty while the real one is running next door.
    return (os.environ.get("POD_TMUX") or _SHELL_PATHS.get("POD_TMUX")
            or shutil.which("tmux") or "tmux")


def _run_tmux(args: list[str]) -> dict[str, Any]:
    proc = subprocess.run([_tmux_bin(), *args], capture_output=True, text=True, check=False,
                          env=_child_env())
    return {"stdout": proc.stdout.strip(), "stderr": proc.stderr.strip(), "returncode": proc.returncode}


def _manager_window(session: str) -> str:
    stamped = _run_tmux(["show-options", "-t", session, "-qv", "@pod_manager_win"])
    if stamped["stdout"]:
        return stamped["stdout"]
    rows = _run_tmux(
        ["list-windows", "-t", f"={session}", "-F", "#{window_id}|#{window_index}"]
    )
    for row in rows["stdout"].splitlines():
        window, _, index = row.partition("|")
        if index == "0":
            return window
    return ""


def _tmux_group() -> dict[str, Any] | None:
    """Active tmux group {session, manager_window, tmux_bin, host, pod} or None.

    Resolves THIS manager's OWN pod first so dispatch scales to secondary pods
    (pod-2, pod-3, ...) instead of always hitting the primary pod that owns the
    global tmux_group.json. This MCP server is spawned by the manager's agent,
    which runs inside a tmux pane, so the server process inherits $TMUX_PANE — and
    that pane's session IS this manager's pod.

    Why TMUX_PANE and not POD_SESSION: the manager window (window 0) is created by
    the launcher BEFORE it sets the session env, so the manager's pane frequently
    lacks POD_SESSION. $TMUX_PANE is always present for an in-tmux process.

    Falls back to the global tmux_group.json for headless callers (mgr-* run outside
    any pane) or if the pane lookup fails — preserving the original behavior there.
    """
    pane = os.environ.get("TMUX_PANE")
    if pane:
        sess = _run_tmux(["display-message", "-p", "-t", pane, "#{session_name}"])
        if sess["returncode"] == 0 and sess["stdout"]:
            is_pod = _run_tmux(["show-options", "-t", sess["stdout"], "-qv", "@is_pod"])
            if is_pod["stdout"] != "1":
                return None
            return {
                "session": sess["stdout"],
                "pod": sess["stdout"],
                "manager_window": _manager_window(sess["stdout"]),
                "tmux_bin": _tmux_bin(),
                "host": _host_short(),
            }
    grp = _read_json(TMUX_GROUP_PATH, None)
    if not isinstance(grp, dict) or not grp.get("session"):
        return None
    res = _run_tmux(["has-session", "-t", f"={grp['session']}"])
    if res["returncode"] != 0:
        return None
    is_pod = _run_tmux(["show-options", "-t", grp["session"], "-qv", "@is_pod"])
    if is_pod["stdout"] != "1":
        return None
    return {
        **grp,
        "pod": grp["session"],
        "manager_window": _manager_window(grp["session"]) or grp.get("manager_window") or "",
    }


def _current_pod_component() -> str:
    """Return the same safe queue namespace the mgr-* helpers resolve.

    Delegated to mgr_current_pod rather than re-derived, because the two rules were
    not the same rule: _tmux_group() additionally demands a LIVE, @is_pod-stamped
    session and answers None otherwise, while the shell reads tmux_group.json's pod
    name verbatim. A pod whose tmux server had restarted therefore had mgr-queue
    writing into _queue/<recorded-name>/ while this side scanned _queue/pod/ — so every
    queued task read back as in-flight and state='queued' returned nothing. The local
    derivation survives only as the fallback for a missing shell layer.
    """
    fields = _mgr_query('printf "%s\\0" "$(mgr_current_pod)"', 1)
    candidate = fields[0] if fields else ""
    if not candidate:
        grp = _tmux_group()
        candidate = (
            (grp or {}).get("pod")
            or os.environ.get("POD_SESSION")
            or os.environ.get("POD_SESSION_PREFIX")
            or "pod"
        )
    if not _valid_component(candidate):
        raise ValueError(f"invalid pod name for queue namespace: {candidate!r}")
    return candidate


def _pod_auto_state() -> tuple[str, str]:
    """(pod, FULL AUTO state) exactly as the shell resolves them: on | off | none.

    'none' means the caller is not in a stamped pod, which mgr_pod_auto_state defines
    as fail-OPEN — a plain tmux session or a headless seat must behave as if the switch
    did not exist. Returns ("", "none") when the shell layer is unreachable, so an
    unanswerable question never blocks a dispatch.
    """
    fields = _mgr_query(
        'p="$(mgr_current_pod)"; printf "%s\\0%s\\0" "$p" "$(mgr_pod_auto_state "$p")"', 2
    )
    if len(fields) < 2 or not fields[1]:
        return "", "none"
    return fields[0], fields[1]


def _scoped_queue_dir() -> Path:
    return QUEUE_DIR / _current_pod_component()


def _scoped_dispatched_dir() -> Path:
    return DISPATCHED_DIR / _current_pod_component()


def _find_worker(
    window_id: int | None = None,
    tmux_window: str | None = None,
    label: str | None = None,
    session: str | None = None,
) -> dict[str, Any] | None:
    data = _read_json(WORKERS_PATH, {"workers": []})
    workers = data.get("workers", []) if isinstance(data, dict) and "_error" not in data else []
    for w in workers:
        if not isinstance(w, dict):
            continue
        if session is not None and w.get("tmux_session") != session:
            continue
        if tmux_window is not None and w.get("tmux_window") == tmux_window:
            return w
        if window_id is not None and w.get("window_id") == window_id:
            return w
        if label is not None and w.get("label") == label:
            return w
    return None


def _apply_tmux_color(win_id: str, color: str) -> None:
    """Tint a worker's whole terminal body AND its status-strip entry with its color.

    The body styles (window-style / window-active-style) MUST carry fg=colour231
    (light) alongside bg. A bg with NO fg lets default text fall back to black and
    render black-on-dark (the black-on-black bug — see lib/palette). With the light
    fg, white text sits readably on the dark palette jewel tones. KEEP the palette
    DARK enough for white text — a too-bright bg washes out an agent's own dim
    secondary text.
    """
    # NOTE: no `bold` on the status styles — match pod-add-worker (the "+" path) and
    # the manager's own style in pod-launch, so an MCP-spawned tab and a +-spawned
    # tab render identically.
    _run_tmux(["setw", "-t", win_id, "window-style", f"fg=colour231,bg={color}"])
    _run_tmux(["setw", "-t", win_id, "window-active-style", f"fg=colour231,bg={color}"])
    _run_tmux(["setw", "-t", win_id, "window-status-style", f"bg={color},fg=colour231"])
    # Active tab swaps the two colors EXPLICITLY — never via the `reverse` attribute.
    # Under reverse, the strip format's #[fg=..] glyphs (state dot, kill ✕, gold ⭐)
    # render swapped too, painting solid color blocks behind them on the selected tab.
    # KEEP IN SYNC with pod-add-worker (the "+" path).
    _run_tmux(["setw", "-t", win_id, "window-status-current-style", f"bg=colour231,fg={color}"])


def _pick_worker_color(session: str, win_id: str) -> tuple[str, str]:
    """First palette entry not already worn by another window's tab in this pod,
    seeded from win_id's numeric part. Mirrors pod-add-worker exactly: starting from the
    window's own id makes concurrent spawns diverge (they don't all converge on one
    "first free" slot), and probing in-use colors avoids clashing with a live tab. This
    replaces `idx = count of tmux workers`, which collided after a kill (the count drops,
    so the next spawn reuses a live worker's color) and ignored colors already in use.
    Returns (name, code).
    """
    palette = _load_palette()
    n = len(palette)
    digits = "".join(ch for ch in win_id if ch.isdigit())
    base = (int(digits) % n) if digits else 0
    used: set[str] = set()
    res = _run_tmux(["list-windows", "-t", session, "-F", "#{window_id} #{window-status-style}"])
    for line in res["stdout"].splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0] != win_id:
            m = re.search(r"bg=(colour\d+)", parts[1])
            if m:
                used.add(m.group(1))
    for k in range(n):
        cname, ccode = palette[(base + k) % n]
        if ccode not in used:
            return cname, ccode
    return palette[base]   # all colors in use (> palette size) -> accept our base slot


def _adapter_field(agent_id: str, key: str, default: str = "") -> str:
    try:
        r = subprocess.run([POD_ADAPTER, "field", agent_id, key],
                           capture_output=True, text=True, timeout=5, env=_child_env())
        if r.returncode == 0:
            return r.stdout.strip()
    except Exception:
        pass
    return default


def _adapter_card(agent_id: str, model: str = "", effort: str = "") -> str:
    try:
        args = [POD_ADAPTER, "card", agent_id]
        if model:
            args += ["--model", model]
        if effort:
            args += ["--effort", effort]
        r = subprocess.run(args,
                           capture_output=True, text=True, timeout=40, env=_child_env())
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return ""


def _detect_window_agent(tmux_window: str) -> str:
    """Ask the adapter catalog to identify a live pane without trusting the caller."""
    pane_cmd = _run_tmux(
        ["display-message", "-p", "-t", tmux_window, "#{pane_current_command}"]
    )["stdout"]
    content = _run_tmux(
        ["capture-pane", "-p", "-t", tmux_window, "-S", "-80"]
    )["stdout"]
    try:
        detected = subprocess.run(
            [POD_ADAPTER, "detect", pane_cmd, content], capture_output=True,
            text=True, timeout=10, env=_child_env(),
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return detected.stdout.strip() if detected.returncode == 0 else ""


def _spawn_tmux_window(label: str, cd_to: str, register: bool, agent_id: str,
                       model: str, effort: str) -> dict[str, Any]:
    """Spawn a worker as a colored tmux window in the active pod session.

    The TAB shows a random human name (via pod-name); the real identity (the agent's
    card) is stamped into the window's #{@card} option, which the pod status bar shows
    when that window is selected. The descriptive `label` is returned to the caller but
    no longer used as the tab name.

    Agent workers launch through the adapter catalog. A generic-shell seat remains
    available for interactive terminal work, but queue dispatch deliberately excludes
    it because a shell cannot consume a natural-language task trigger.
    """
    grp = _tmux_group()
    if not grp:
        return {"error": "tmux pod not active",
                "hint": "start the manager with pod-launch to group workers as tmux windows"}
    session = grp["session"]
    # Random friendly name for the tab (avoids collisions with current tabs). Fall
    # back to the sanitized-label behavior only if pod-name is unavailable.
    name = ""
    try:
        r = subprocess.run([str(POD_BIN / "pod-name"), session],
                           capture_output=True, text=True, timeout=5, env=_child_env())
        name = r.stdout.strip()
    except Exception:
        name = ""
    if not name:
        name = label.replace('"', "'").replace("'", "")[:40] or "worker"

    target = Path(cd_to).expanduser().resolve()
    if not target.is_dir():
        return {"error": f"working directory does not exist or is not a directory: {target}"}
    shell = os.environ.get("SHELL") or "/bin/bash"
    resolved_model = model
    if agent_id != "generic-shell":
        try:
            resolved = subprocess.run(
                [POD_ADAPTER, "resolve-model", agent_id, model], capture_output=True,
                text=True, timeout=40, env=_child_env(),
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"could not resolve local models for '{agent_id}': {exc}"}
        if resolved.returncode == 0:
            resolved_model = resolved.stdout.strip()
        try:
            resolved_effort_proc = subprocess.run(
                [POD_ADAPTER, "resolve-effort", agent_id, resolved_model, effort],
                capture_output=True, text=True, timeout=40, env=_child_env(),
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"could not resolve effort for '{agent_id}': {exc}"}
        resolved_effort = (
            resolved_effort_proc.stdout.strip()
            if resolved_effort_proc.returncode == 0 else ""
        )
        args = [POD_ADAPTER, "launch", agent_id]
        if resolved_model:
            args += ["--model", resolved_model]
        if resolved_effort:
            args += ["--effort", resolved_effort]
        try:
            launched = subprocess.run(args, capture_output=True, text=True, timeout=40,
                                      env=_child_env())
        except (OSError, subprocess.SubprocessError) as exc:
            return {"error": f"could not launch adapter '{agent_id}': {exc}"}
        command = launched.stdout.strip() if launched.returncode == 0 else ""
        if not command:
            return {"error": f"adapter could not launch agent '{agent_id}'",
                    "stderr": launched.stderr.strip()}
        bootstrap = POD_BIN / "pod-worker-bootstrap"
        # Hand the adapter's argv straight to the bootstrap, exactly as pod-add-worker
        # does (`exec "$POD_BIN/pod-worker-bootstrap" $CMD`) — the two spawn paths must
        # produce identical panes. The old `$SHELL -lc <cmd>` wrapper broke that twice:
        # csh/tcsh reject a combined -lc outright ("Unknown option: `-lc'"), so the pane
        # died milliseconds after new-window reported success; and even under bash, -l
        # sourced the login profile, dumping banners and a re-ordered PATH into the
        # agent's pane that a "+"-spawned worker never sees. `command` stays unquoted
        # because it is a space-joined argv meant for the spawning shell to split.
        launch = (f"cd {shlex.quote(str(target))} && "
                  f"exec {shlex.quote(str(bootstrap))} {command}")
    else:
        resolved_effort = ""
        launch = f"cd {shlex.quote(str(target))} && exec {shlex.quote(shell)}"
    res = _run_tmux(["new-window", "-d", "-t", session, "-n", name,
                     "-P", "-F", "#{window_id}", launch])
    if res["returncode"] != 0:
        return {"error": f"tmux new-window failed: {res['stderr']}", "raw": res}
    win = res["stdout"].strip()
    cname, ccode = _pick_worker_color(session, win)
    _apply_tmux_color(win, ccode)

    # Identity card from the catalog (matches a +-spawned generic-shell tab).
    agent_label = _adapter_field(agent_id, "label", agent_id)
    card = _adapter_card(agent_id, resolved_model, resolved_effort) or agent_label
    native = "1" if _adapter_field(agent_id, "native_delivery") == "true" else "0"
    for opt, val in (("@card", card), ("@agent", agent_label),
                     ("@agent_id", agent_id), ("@model", resolved_model),
                     ("@effort", resolved_effort), ("@pod_native_delivery", native)):
        _run_tmux(["set-option", "-w", "-t", win, opt, val])
    out: dict[str, Any] = {
        "status": "ok", "dispatch_mode": "tmux", "tmux_session": session,
        "tmux_window": win, "color": cname, "label": name, "card": card,
        "requested_label": label,
    }
    if register:
        registry = pod_register_worker(
            window_id=None, label=name, host=grp.get("host", "localhost"),
            dispatch_mode="tmux", tmux_session=session, tmux_window=win, color=cname,
            agent_type=agent_label, agent_id=agent_id, model=resolved_model,
            effort=resolved_effort, card=card,
        )
        out["worker_registry"] = registry
        if "error" in registry:
            _run_tmux(["kill-window", "-t", win])
            return {"error": "worker registration failed; new window was rolled back",
                    "detail": registry}
    _run_tmux(["set-option", "-w", "-t", win, "@pod_registered", "1"])
    return out


# ============================================================
# BOOTSTRAP
# ============================================================


@mcp.tool()
def pod_init(force: bool = False) -> dict[str, Any]:
    """Bootstrap the inbox + state trees with state files and default templates.

    Creates the inbox root, state dir, per-pod queue roots, templates, dispatched,
    and completion directories.
    Writes inbox-config.json, workers.json (empty), log.jsonl (empty), and copies the
    default templates (audit, execute, investigate, plan) plus their
    _registry.json sidecar from the queue module.

    Idempotent unless force=True (which overwrites existing config + templates).
    workers.json and queue contents are never overwritten.

    Returns a summary of what was created vs. left alone.
    """
    required = [POD_LAUNCHER, POD_BIN / "pod-worker-bootstrap",
                MGR_BIN / "mgr-stage", MGR_BIN / "mgr-dispatch",
                REPO_TEMPLATES / "_registry.json", REPO_TEMPLATES / "plan.tpl.txt"]
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        return {
            "error": "pod-manager runtime resources are missing",
            "missing": missing,
            "hint": "run this module from an agent-pods clone or set POD_REPO/POD_BIN/POD_MODULES",
        }
    layout_error = _runtime_layout_error(create=True)
    if layout_error:
        return {"error": layout_error}
    created: list[str] = []
    skipped: list[str] = []

    for d in (
        INBOX_ROOT,
        STATE_DIR,
        QUEUE_DIR,
        TEMPLATES_DIR,
        DISPATCHED_DIR,
        COMPLETED_DIR,
    ):
        if d.exists():
            skipped.append(f"dir: {d}")
        else:
            d.mkdir(parents=True, exist_ok=True)
            created.append(f"dir: {d}")
        os.chmod(d, 0o700)

    config = {
        "inbox_root": str(INBOX_ROOT),
        "state_dir": str(STATE_DIR),
        "templates_dir": str(TEMPLATES_DIR),
        "queue_dir": str(QUEUE_DIR),  # compatibility: now a root of per-pod dirs
        "queue_root": str(QUEUE_DIR),
        "workers_path": str(WORKERS_PATH),
        "log_path": str(LOG_PATH),
        "dispatched_archive": str(DISPATCHED_DIR),  # compatibility root
        "dispatched_root": str(DISPATCHED_DIR),
        "completed_root": str(COMPLETED_DIR),
        "trigger_template": (
            f"Read {INBOX_ROOT}/{{{{task_id}}}}/prompt.txt and execute the "
            "task it describes end-to-end. Write result.json, touch DONE as "
            "your last action."
        ),
        "default_priority": 100,
    }
    if not CONFIG_PATH.exists() or force:
        _write_json(CONFIG_PATH, config)
        created.append(f"file: {CONFIG_PATH}")
    else:
        skipped.append(f"file: {CONFIG_PATH}")

    if not WORKERS_PATH.exists():
        _write_json(WORKERS_PATH, {"workers": []})
        created.append(f"file: {WORKERS_PATH}")
    else:
        skipped.append(f"file: {WORKERS_PATH}")

    if not LOG_PATH.exists():
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        LOG_PATH.touch()
        os.chmod(LOG_PATH, 0o600)
        created.append(f"file: {LOG_PATH}")
    else:
        skipped.append(f"file: {LOG_PATH}")

    if REPO_TEMPLATES.is_dir():
        for src in REPO_TEMPLATES.glob("*.tpl.txt"):
            dst = TEMPLATES_DIR / src.name
            if dst.exists() and not force:
                skipped.append(f"template: {src.name}")
            else:
                shutil.copy2(src, dst)
                created.append(f"template: {src.name}")

        src_registry = REPO_TEMPLATES / "_registry.json"
        if src_registry.exists():
            if REGISTRY_PATH.exists() and not force:
                skipped.append(f"registry: {REGISTRY_PATH.name}")
            else:
                shutil.copy2(src_registry, REGISTRY_PATH)
                created.append(f"registry: {REGISTRY_PATH.name}")

    return {
        "status": "ok",
        "inbox_root": str(INBOX_ROOT),
        "state_dir": str(STATE_DIR),
        "created": created,
        "skipped": skipped,
        "next_step": "pod_list_templates() to see what's available, then pod_spawn_window() to open a worker.",
    }


# ============================================================
# DISCOVERY (Library)
# ============================================================


def _load_registry() -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    """Load the template registry, returning (registry, None) on success or
    (None, error) when the registry is missing or corrupt.

    A corrupt registry surfaces from _read_json as a dict carrying an "_error"
    key. Because that is still a dict, a bare isinstance check lets it through and
    the corruption leaks downstream as a phantom "_error" template. Treating an
    "_error" key as malformed closes that hole for every registry consumer.
    """
    registry = _read_json(REGISTRY_PATH, {})
    if not isinstance(registry, dict) or "_error" in registry:
        detail = registry.get("_error") if isinstance(registry, dict) else None
        return None, {"error": f"registry malformed at {REGISTRY_PATH}", "detail": detail}
    return registry, None


@mcp.tool()
def pod_list_templates() -> dict[str, Any]:
    """List all available worker templates with their metadata.

    Returns each template's name, description (read this to decide which one
    fits the task), model_preference, tools_allowed, permission_mode,
    required_vars, optional_vars, and proactive flag.

    Use this BEFORE pod_stage() to pick the right template.
    """
    err = _ensure_initialized()
    if err:
        return err
    registry, rerr = _load_registry()
    if rerr:
        return rerr
    return {
        "status": "ok",
        "templates": [{"name": name, **meta} for name, meta in registry.items()],
        "count": len(registry),
    }


@mcp.tool()
def pod_get_template(name: str) -> dict[str, Any]:
    """Return the full body + metadata for one template.

    Useful when you want to see the {{var}} placeholders and constraint
    language before staging a task with it.
    """
    err = _ensure_initialized()
    if err:
        return err
    if not _valid_component(name):
        return {"error": "template name must be one safe path component"}
    registry, rerr = _load_registry()
    if rerr:
        return rerr
    if name not in registry:
        return {"error": f"template '{name}' not in registry", "available": list(registry.keys())}
    meta = registry[name]
    if not isinstance(meta, dict):
        return {"error": f"template metadata for '{name}' must be an object"}
    body_file = meta.get("body_file", f"{name}.tpl.txt")
    if not isinstance(body_file, str) or Path(body_file).name != body_file:
        return {"error": f"template body_file for '{name}' must be one safe filename"}
    body_path = TEMPLATES_DIR / body_file
    body = body_path.read_text() if body_path.exists() else None
    return {
        "status": "ok",
        "name": name,
        "metadata": meta,
        "body": body,
        "body_path": str(body_path),
    }


# ============================================================
# WORKERS (Running)
# ============================================================


@mcp.tool()
def pod_list_workers() -> dict[str, Any]:
    """List all registered workers with status + elapsed time per busy worker.

    Reads workers.json. Each entry has tmux_window (e.g. "@7"), label, status
    (idle|busy), current_task_id, started_at, and (for busy workers) elapsed_seconds.
    """
    err = _ensure_initialized()
    if err:
        return err
    data = _read_json(WORKERS_PATH, {"workers": []})
    if not isinstance(data, dict) or "_error" in data:
        detail = data.get("_error") if isinstance(data, dict) else "root is not an object"
        return {"error": f"workers registry is unreadable: {detail}"}
    workers = data.get("workers")
    if not isinstance(workers, list) or any(not isinstance(w, dict) for w in workers):
        return {"error": "workers registry must contain an array of objects"}
    grp = _tmux_group()
    if grp:
        workers = [w for w in workers if w.get("tmux_session") == grp["session"]]
    enriched = []
    for w in workers:
        elapsed = _elapsed_seconds(w.get("started_at")) if w.get("status") == "busy" else None
        enriched.append({**w, "elapsed_seconds": elapsed})
    return {
        "status": "ok",
        "workers": enriched,
        "idle_count": sum(1 for w in enriched if w.get("status") == "idle"),
        "busy_count": sum(1 for w in enriched if w.get("status") == "busy"),
    }


@mcp.tool()
def pod_spawn_window(
    label: str,
    cd_to: str | None = None,
    register: bool = True,
    agent_id: str = "generic-shell",
    model: str = "",
    effort: str = "",
) -> dict[str, Any]:
    """Open a new colored worker window in the active pod and (by default) register it.

    Spawns an adapter-backed agent, or a generic shell when agent_id is left at its
    default. Generic shells are useful interactively but are not eligible for queue
    dispatch because they cannot consume natural-language triggers.

    label: descriptive label for the worker; returned to the caller. The tab itself
        gets a random friendly name.
    cd_to: directory to cd into before launching. Default is $HOME.
    register: if True (default), also append the new window to workers.json so
        pod_dispatch can auto-pick it.
    agent_id/model/effort: adapter selection. For dispatchable workers, pass an
        installed agent_id such as "claude-code" or "codex".

    Returns the new window's id and the worker registry entry (if registered).
    """
    err = _ensure_initialized()
    if err:
        return err
    if not _tmux_group():
        return {"error": "tmux pod not active",
                "hint": "start the manager with pod-launch to group workers as tmux windows"}
    if not POD_LAUNCHER.exists():
        return {"error": f"pod launcher not at {POD_LAUNCHER}"}
    target_dir = cd_to or os.environ.get("HOME") or os.getcwd()
    return _spawn_tmux_window(label, target_dir, register, agent_id, model, effort)


@mcp.tool()
def pod_register_worker(
    window_id: int | None = None,
    label: str | None = None,
    host: str = "localhost",
    dispatch_mode: str = "tmux",
    tmux_session: str | None = None,
    tmux_window: str | None = None,
    color: str | None = None,
    agent_type: str | None = None,
    agent_id: str | None = None,
    model: str | None = None,
    effort: str | None = None,
    card: str | None = None,
) -> dict[str, Any]:
    """Add a worker (tmux window) to workers.json.

    Use when a worker exists but isn't yet tracked. dispatch_mode "tmux" workers
    are addressed by tmux_window (e.g. "@7").

    agent_type/model/effort/card describe the agent's identity; they keep the
    registry schema in parity with the "+" button path (pod-add-worker), so `pod`,
    pod-summary, mgr-status and pod_list_workers see the same fields regardless of
    which path spawned the worker.
    """
    err = _ensure_initialized()
    if err:
        return err
    grp = _tmux_group()
    if not grp:
        return {"error": "tmux pod not active"}
    if dispatch_mode != "tmux" or not tmux_window:
        return {"error": "only live tmux workers can be registered"}
    session = tmux_session or grp["session"]
    if session != grp["session"]:
        return {"error": f"refusing cross-pod registration: caller={grp['session']}, target={session}"}
    live = _run_tmux(["display-message", "-p", "-t", tmux_window, "#{session_name}"])
    if live["returncode"] != 0 or live["stdout"] != session:
        return {"error": f"tmux window {tmux_window} is not live in pod {session}"}
    if tmux_window == grp.get("manager_window"):
        return {"error": "refusing to register the manager as a worker"}
    stamped = _run_tmux(["show-options", "-w", "-t", tmux_window,
                         "-qv", "@agent_id"])["stdout"]
    detected = _detect_window_agent(tmux_window)
    observed = stamped or detected or "generic-shell"
    if agent_id and observed != "generic-shell" and agent_id != observed:
        return {"error": f"agent identity mismatch: requested={agent_id}, observed={observed}"}
    if agent_id and observed == "generic-shell" and agent_id != "generic-shell":
        return {"error": f"could not verify requested agent '{agent_id}' in {tmux_window}"}
    agent_id = agent_id or observed
    entry = {
        "window_id": window_id,
        "dispatch_mode": dispatch_mode,
        "tmux_session": session,
        "tmux_window": tmux_window,
        "color": color,
        "agent_type": agent_type,
        "agent_id": agent_id,
        "model": model,
        "effort": effort,
        "card": card,
        "label": label or tmux_window or f"worker-{window_id}",
        "host": host,
        "status": "idle",
        "current_task_id": None,
        "started_at": None,
        "registered_at": _now_iso(),
    }
    def register(workers: list[dict[str, Any]]) -> dict[str, Any]:
        workers[:] = [w for w in workers if not (
            w.get("tmux_window") == tmux_window and w.get("tmux_session") != session
        )]
        existing = next((w for w in workers if w.get("tmux_session") == session
                         and w.get("tmux_window") == tmux_window), None)
        if window_id is not None and any(w is not existing and w.get("window_id") == window_id
                                         for w in workers):
            return {"status": "noop", "reason": f"window {window_id} already registered"}
        if existing is not None:
            assignment = {key: existing.get(key) for key in
                          ("status", "current_task_id", "started_at", "registered_at")
                          if key in existing}
            existing.update(entry)
            existing.update(assignment)
            return {"status": "ok", "worker": existing, "updated": True}
        workers.append(entry)
        return {"status": "ok", "worker": entry}
    result = _mutate_workers(register)
    if isinstance(result, dict) and "error" not in result:
        for opt, value in (("@agent_id", agent_id), ("@agent", agent_type or agent_id),
                           ("@model", model or ""), ("@effort", effort or ""),
                           ("@card", card or agent_type or agent_id)):
            _run_tmux(["set-option", "-w", "-t", tmux_window, opt, value])
        native = "1" if _adapter_field(agent_id, "native_delivery") == "true" else "0"
        _run_tmux(["set-option", "-w", "-t", tmux_window,
                   "@pod_native_delivery", native])
        _run_tmux(["set-option", "-w", "-t", tmux_window,
                   "@pod_registered", "1"])
    return result


@mcp.tool()
def pod_window_contents(window_id: int | None = None, last_n_lines: int | None = 80,
                        tmux_window: str | None = None) -> dict[str, Any]:
    """Peek at a worker's current text (tmux window).

    Pass tmux_window ("@7") for a grouped worker, or window_id to look it up in the
    roster (which resolves to its tmux_window).

    last_n_lines: tail of the buffer (default 80). None (or 0) = full scrollback.
    """
    err = _ensure_initialized()
    if err:
        return err
    grp = _tmux_group()
    if not grp:
        return {"error": "tmux pod not active"}
    rec = _find_worker(
        window_id=window_id, tmux_window=tmux_window, session=grp["session"]
    )
    tw = rec.get("tmux_window") if rec else None
    if not tw:
        return {"error": "target must be a registered worker in this pod"}
    if rec.get("tmux_session") != grp["session"]:
        return {"error": "refusing cross-pod or inactive worker target"}
    live = _run_tmux(["display-message", "-p", "-t", tw, "#{session_name}"])
    if live["returncode"] != 0 or live["stdout"] != grp["session"]:
        return {"error": "registered worker is not live in this pod", "tmux_window": tw}
    # "None = full contents" has to mean the WHOLE history (-S -), not a silent 200-line
    # cap: the old fallback captured 200 lines and then computed truncated against a
    # None cap, so it always answered truncated=false. A manager hunting for an error
    # the worker printed 300 lines ago was told, explicitly, that nothing had been cut.
    cap = last_n_lines if (last_n_lines and last_n_lines > 0) else None
    start = f"-{cap}" if cap else "-"
    res = _run_tmux(["capture-pane", "-p", "-t", tw, "-S", start])
    if res["returncode"] != 0:
        return {"error": f"capture-pane failed: {res['stderr']}", "tmux_window": tw}
    content = res["stdout"]
    lines = content.splitlines()
    truncated = bool(cap and len(lines) > cap)
    if truncated:
        content = "\n".join(lines[-cap:])
    return {"status": "ok", "tmux_window": tw, "contents": content,
            "truncated": truncated}


# ============================================================
# DISPATCH (wraps mgr-*)
# ============================================================


@mcp.tool()
def pod_stage(
    template: str, vars: dict[str, str], task_id: str | None = None
) -> dict[str, Any]:
    """Stage a prompt by substituting vars into a template.

    Validates required_vars against the template registry before calling
    mgr-stage. Returns the resolved task_id and the path to the staged prompt.

    template: name from pod_list_templates() (audit, execute, investigate, plan)
    vars: dict of {{key}} -> value substitutions. All required_vars for the
        template must be present.
    task_id: optional override. If omitted, mgr-stage auto-allocates
        <template>-<N>.
    """
    err = _ensure_initialized()
    if err:
        return err
    if not _valid_component(template):
        return {"error": "template must be one safe path component"}
    if task_id is not None and not _valid_component(task_id):
        return {"error": "task_id must use only letters, digits, dot, underscore and hyphen"}
    registry, rerr = _load_registry()
    if rerr:
        return rerr
    if template not in registry:
        return {"error": f"template '{template}' not in registry", "available": list(registry.keys())}

    meta = registry[template]
    required = set(meta.get("required_vars", []))
    provided = set(vars.keys())
    missing = required - provided
    if missing:
        return {
            "error": f"missing required vars for template '{template}': {sorted(missing)}",
            "required_vars": sorted(required),
            "optional_vars": meta.get("optional_vars", []),
        }

    args = [template]
    if task_id:
        args += ["--id", task_id]
    for k, v in vars.items():
        args.append(f"{k}={v}")

    res = _run_mgr("mgr-stage", args)
    if res["returncode"] != 0:
        return {"error": res.get("error", "mgr-stage failed"), **res}
    resolved_id = res["stdout"].strip().splitlines()[-1] if res["stdout"] else None
    return {
        "status": "ok",
        "task_id": resolved_id,
        "prompt_path": f"{INBOX_ROOT}/{resolved_id}/prompt.txt",
        "template": template,
        "mgr_stdout": res["stdout"],
        "mgr_stderr": res["stderr"],
    }


@mcp.tool()
def pod_queue(
    task_id: str,
    priority: int = 100,
    description: str = "",
    template: str = "",
    deps: list[str] | None = None,
) -> dict[str, Any]:
    """Add a staged task to the dispatch queue.

    Lower priority number = higher priority (010-039 critical, 040-069
    important, 070-099 standard, 100-149 cosmetic, 150+ nice-to-have).
    """
    err = _ensure_initialized()
    if err:
        return err
    if not _valid_component(task_id):
        return {"error": "task_id must use only letters, digits, dot, underscore and hyphen"}
    if template and not _valid_component(template):
        return {"error": "template must be one safe path component"}
    if deps and any(not _valid_component(dep) for dep in deps):
        return {"error": "every dependency id must be one safe path component"}
    args = [task_id, "--priority", str(priority)]
    if description:
        args += ["--description", description]
    if template:
        args += ["--template", template]
    if deps:
        args += ["--deps", ",".join(deps)]
    res = _run_mgr("mgr-queue", args)
    if res["returncode"] != 0:
        return {"error": res.get("error", "mgr-queue failed"), **res}
    return {
        "status": "ok",
        "task_id": task_id,
        "queue_file": res["stdout"],
        "priority": priority,
    }


@mcp.tool()
def pod_dispatch(
    task_id: str | None = None,
    tmux_window: str | None = None,
    print_only: bool = False,
) -> dict[str, Any]:
    """Fire a queued task at a worker window (via mgr-dispatch send-keys).

    Defaults: highest-priority queued task -> first idle worker. Override
    either side with task_id / tmux_window. print_only=True returns the
    command that would fire without actually firing it (dry run).

    Gated by the pod's FULL AUTO switch, same as pod_pick_next: while the strip shows
    ✋ MAN, picking a worker automatically is refused. Passing tmux_window is the
    deliberate, always-allowed act (that is the scope pod-auto documents), so a human
    or an agent acting on a human's instruction can still dispatch by hand.
    """
    err = _ensure_initialized()
    if err:
        return err
    if tmux_window is None:
        # Pre-flight the switch here so an MCP manager gets a typed refusal it can
        # branch on instead of a non-zero exit plus a stderr string — and so the gate
        # holds even against a queue module older than the one that enforces it inside
        # mgr-dispatch. The rule itself is still the shell's (mgr_pod_auto_state).
        pod, auto = _pod_auto_state()
        if auto == "off":
            return {
                "error": f"FULL AUTO is OFF for pod '{pod}' — automatic worker-picking "
                         "is held. Pass tmux_window to dispatch by hand, or run "
                         "`pod-auto on`.",
                "pod": pod,
                "full_auto": auto,
            }
    args: list[str] = []
    if task_id:
        if not _valid_component(task_id):
            return {"error": "task_id must use only letters, digits, dot, underscore and hyphen"}
        args += ["--task", task_id]
    if tmux_window is not None:
        args += ["--tmux-window", str(tmux_window)]
    if print_only:
        args.append("--print-only")
    res = _run_mgr("mgr-dispatch", args)
    if res["returncode"] != 0:
        return {"error": res.get("error", "mgr-dispatch failed"), **res}
    return {"status": "ok", "output": res["stdout"], "stderr": res["stderr"]}


@mcp.tool()
def pod_poll() -> dict[str, Any]:
    """Sweep the inbox for newly-completed tasks (DONE sentinels).

    Frees the corresponding workers (idle in workers.json) and returns the
    list of freed task_ids. Idempotent — running with no completions returns
    an empty list.
    """
    err = _ensure_initialized()
    if err:
        return err
    # --quiet as well as --json: --json alone still prints "no newly-completed tasks"
    # ahead of the array on the (very common) empty sweep, which is not parseable JSON.
    res = _run_mgr("mgr-poll", ["--json", "--quiet"])
    if res["returncode"] != 0:
        return {"error": res.get("error", "mgr-poll failed"), **res}
    try:
        freed = json.loads(res["stdout"]) if res["stdout"] else []
    except json.JSONDecodeError:
        freed = None
    # An unparseable sweep is an ERROR, never an empty success. Reporting count 0 for
    # garbage on stdout (a jq error, a warning from a sourced config.sh, a truncated
    # pipe) tells the manager "nobody finished" forever: workers are never freed and the
    # queue stalls with nothing surfaced anywhere. Matches pod_status's handling.
    if not isinstance(freed, list):
        return {"error": "mgr-poll did not emit a JSON array", "raw_stdout": res["stdout"],
                "stderr": res["stderr"]}
    return {"status": "ok", "freed_task_ids": freed, "count": len(freed)}


@mcp.tool()
def pod_pick_next(all_idle: bool = False, print_only: bool = False) -> dict[str, Any]:
    """Composite: poll for completions, then dispatch the next queued task to
    any worker that just freed (or any already-idle worker).

    Designed to be called at the top of every manager turn. all_idle=True
    drains the queue across all currently-idle workers in one call.
    """
    err = _ensure_initialized()
    if err:
        return err
    args: list[str] = []
    if all_idle:
        args.append("--all-idle")
    if print_only:
        args.append("--print-only")
    res = _run_mgr("mgr-pick-next", args)
    return {
        "status": "ok" if res["returncode"] == 0 else "error",
        "output": res["stdout"],
        "stderr": res["stderr"],
        "returncode": res["returncode"],
    }


@mcp.tool()
def pod_status() -> dict[str, Any]:
    """Full state snapshot: workers, queue, recent completions, inbox root."""
    err = _ensure_initialized()
    if err:
        return err
    res = _run_mgr("mgr-status", ["--json"])
    if res["returncode"] != 0:
        return {"error": res.get("error", "mgr-status failed"), **res}
    try:
        data = json.loads(res["stdout"]) if res["stdout"] else {}
    except json.JSONDecodeError:
        return {"error": "could not parse mgr-status JSON", "raw_stdout": res["stdout"]}
    return {"status": "ok", **data}


# ============================================================
# RESULTS
# ============================================================


@mcp.tool()
def pod_read_result(task_id: str) -> dict[str, Any]:
    """Read <inbox>/<task_id>/result.json plus DONE / EXECUTED state."""
    err = _ensure_initialized()
    if err:
        return err
    if not _valid_component(task_id):
        return {"error": "invalid task_id"}
    task_dir = INBOX_ROOT / task_id
    if not task_dir.exists():
        return {"error": f"no inbox dir for {task_id}", "expected": str(task_dir)}
    result_path = task_dir / "result.json"
    done = (task_dir / "DONE").exists()
    executed = (task_dir / "EXECUTED").exists()
    result = _read_json(result_path) if result_path.exists() else None
    return {
        "status": "ok",
        "task_id": task_id,
        "done": done,
        "executed": executed,
        "result": result,
        "result_path": str(result_path),
    }


@mcp.tool()
def pod_read_prompt(task_id: str) -> dict[str, Any]:
    """Read the prompt that was staged for a task."""
    err = _ensure_initialized()
    if err:
        return err
    if not _valid_component(task_id):
        return {"error": "invalid task_id"}
    prompt_path = INBOX_ROOT / task_id / "prompt.txt"
    if not prompt_path.exists():
        return {"error": f"no prompt.txt for {task_id}", "expected": str(prompt_path)}
    return {
        "status": "ok",
        "task_id": task_id,
        "prompt": prompt_path.read_text(),
        "prompt_path": str(prompt_path),
    }


@mcp.tool()
def pod_list_inbox(state: str = "all") -> dict[str, Any]:
    """List all task dirs under the inbox root, optionally filtered.

    state: 'all' | 'staged' | 'queued' | 'in-flight' | 'done'
        - staged: prompt written, not queued and never dispatched
        - queued: in _queue/<pod>/ but not yet dispatched
        - in-flight: dispatched (archive present) but no DONE sentinel
        - done: DONE sentinel present
    """
    err = _ensure_initialized()
    if err:
        return err
    if not INBOX_ROOT.exists():
        return {"error": f"inbox root missing: {INBOX_ROOT}"}

    try:
        queue_dir = _scoped_queue_dir()
        dispatched_dir = _scoped_dispatched_dir()
    except ValueError as exc:
        return {"error": str(exc)}
    queued_ids: set[str] = set()
    if queue_dir.exists():
        for f in queue_dir.iterdir():
            if f.suffix == ".json":
                qdata = _read_json(f, {})
                if isinstance(qdata, dict) and qdata.get("task_id"):
                    queued_ids.add(qdata["task_id"])

    tasks = []
    for d in sorted(INBOX_ROOT.iterdir()):
        if not d.is_dir() or d.name.startswith("_"):
            continue
        done = (d / "DONE").exists() or (d / "EXECUTED").exists()
        if done:
            task_state = "done"
        elif d.name in queued_ids:
            task_state = "queued"
        elif (dispatched_dir / f"{d.name}.json").exists():
            # mgr-dispatch archives the queue record here the moment it fires, so this
            # file — not "everything left over" — is what in-flight actually means.
            task_state = "in-flight"
        else:
            # Staged but never queued. Calling this in-flight told a manager a worker
            # was executing a task nobody had dispatched, and it waited for a DONE that
            # no one would ever write.
            task_state = "staged"
        if state != "all" and task_state != state:
            continue
        tasks.append(
            {
                "task_id": d.name,
                "state": task_state,
                "has_prompt": (d / "prompt.txt").exists(),
                "has_result": (d / "result.json").exists(),
            }
        )
    return {"status": "ok", "filter": state, "tasks": tasks, "count": len(tasks)}


# ============================================================
# INTERVENTION (experimental — use sparingly)
# ============================================================


@mcp.tool()
def pod_send_input(
    tmux_window: str | None = None, text: str = "", submit: bool = False,
    window_id: int | None = None,
) -> dict[str, Any]:
    """Type text into a running worker (tmux window).

    EXPERIMENTAL. Use sparingly — workers run autonomously and unsolicited input
    mid-flight can confuse them. Pass tmux_window ("@7") for a grouped worker, or a
    window_id that resolves in the roster. Refuses to send into the manager window.
    submit=True presses Return after.

    Newlines and tabs in `text` are flattened to spaces before sending (see
    text_flattened in the return); only submit=True submits.
    """
    err = _ensure_initialized()
    if err:
        return err
    grp = _tmux_group()
    if not grp:
        return {"error": "tmux pod not active"}
    rec = _find_worker(
        window_id=window_id, tmux_window=tmux_window, session=grp["session"]
    )
    tw = rec.get("tmux_window") if rec else None
    if not tw:
        return {"error": "target must be a registered worker in this pod"}
    if rec.get("tmux_session") != grp.get("session"):
        return {"error": "refusing cross-pod worker target"}
    live = _run_tmux(["display-message", "-p", "-t", tw, "#{session_name}"])
    if live["returncode"] != 0 or live["stdout"] != grp.get("session"):
        return {"error": "registered worker is not live in this pod", "tmux_window": tw}
    if tw == grp.get("manager_window"):
        return {"error": "refusing to send into the manager window"}
    # `send-keys -l` writes the bytes literally, and a literal 0x0a IS Enter to the
    # pane's terminal — so a multi-line message submitted every line but the last while
    # this function still reported submitted=false. Flatten first, exactly as
    # pod-deliver does (`tr '\n\r\t' '   '`); tabs go too because a bare tab triggers
    # completion in most agent TUIs. Submission stays the caller's explicit choice.
    payload = text.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    flattened = payload != text
    r1 = _run_tmux(["send-keys", "-t", tw, "-l", payload])
    if r1["returncode"] != 0:
        return {"error": f"send-keys failed: {r1['stderr']}", "tmux_window": tw}
    submitted = False
    if submit:
        # Small gap so Enter can't race ahead of the typed text before the TUI
        # registers it. Measured reliable at 0.1; matches mgr-dispatch. Imperceptible,
        # and closes the latent race a back-to-back submit could hit under load.
        time.sleep(0.1)
        r2 = _run_tmux(["send-keys", "-t", tw, "Enter"])
        if r2["returncode"] != 0:
            _run_tmux(["send-keys", "-t", tw, "C-u"])
            return {"error": f"submit failed: {r2['stderr']}", "tmux_window": tw,
                    "text_length": len(payload), "text_flattened": flattened,
                    "submitted": False}
        submitted = True
    return {"status": "ok", "tmux_window": tw, "text_length": len(payload),
            "text_flattened": flattened, "text_sent": payload, "submitted": submitted}


# ============================================================
# GROUP STATUS
# ============================================================


@mcp.tool()
def pod_group_status() -> dict[str, Any]:
    """Report whether grouped (tmux) mode is active and list the deck's windows.

    grouped=False means there is no active pod. Start the manager via pod-launch to
    group workers as colored tmux windows in one deck.

    full_auto is the pod's FULL AUTO switch (on | off | none, where none = not a
    stamped pod and therefore unrestricted). Check it before pod_dispatch /
    pod_pick_next: while it is off, automatic worker-picking is held.
    """
    grp = _tmux_group()
    if not grp:
        return {"status": "ok", "grouped": False,
                "hint": "launch the manager with pod-launch to group workers as colored tmux windows"}
    res = _run_tmux(["list-windows", "-t", grp["session"],
                     "-F", "#{window_id} #{window_index}:#{window_name}"])
    _, auto = _pod_auto_state()
    return {
        "status": "ok",
        "grouped": True,
        "session": grp["session"],
        "manager_window": grp.get("manager_window"),
        "full_auto": auto,
        "windows": res["stdout"].splitlines(),
    }


def main() -> None:
    """Console entry point (stdio MCP transport)."""
    mcp.run()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Claude Code hook for Vigil: tells the menu bar app when Claude is working.

One script for every event. It writes one small marker file per Claude Code session:

  UserPromptSubmit, PreToolUse, PostToolUse        -> state "busy"
  Notification: permission prompt or question      -> state "waiting"
  Notification: idle prompt, Stop                  -> state "idle"
  SessionEnd                                       -> marker removed

The marker holds only the state, the pid of the owning `claude` process, a timestamp,
and the name of the session's project folder (the last part of its working directory).
Nothing else from the hook payload (prompt text, tool input or output, messages) is ever
stored. Vigil treats a marker as working only while that pid is a live `claude` process and
the marker is recent, so a crashed, killed or interrupted session cannot keep the Mac awake.

The hook never blocks Claude: it prints nothing and always exits 0.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SESSIONS_DIR = Path.home() / "Library" / "Application Support" / "Vigil" / "sessions"

BUSY_EVENTS = {"UserPromptSubmit", "PreToolUse", "PostToolUse"}
NOTIFICATION = "Notification"
# Claude asks the user something mid-task. Vigil keeps the Mac awake (the answer usually
# starts a tool that fires no hook until it finishes) and tells the user it is waiting.
WAITING_NOTIFICATIONS = {"permission_prompt", "elicitation_dialog"}
# Claude finished and has sat at the prompt for a while.
IDLE_NOTIFICATIONS = {"idle_prompt"}
STOP = "Stop"
SESSION_END = "SessionEnd"

# Session ids are UUIDs; anything else is reduced to a safe file name.
_UNSAFE = re.compile(r"[^A-Za-z0-9_-]")
# Hooks run through a shell or two below `claude`; never walk further than this.
_MAX_HOPS = 12
# The whole walk must finish well inside the hook timeout (TIMEOUT_SECONDS in install_hooks.py).
_WALK_DEADLINE_SECONDS = 1.5
# The shortest timeout handed to a single `ps` near the deadline.
_MIN_PS_TIMEOUT = 0.05
_MAX_PROJECT_NAME = 80
# PostToolUse carries the tool output, so payloads can be large. This only stops a runaway
# one from eating memory: a payload past the cap fails to parse and the event is skipped.
_MAX_STDIN = 64 * 1024 * 1024


def marker_path(session_id: str) -> Path | None:
    name = _UNSAFE.sub("", session_id)[:128]
    return SESSIONS_DIR / f"{name}.json" if name else None


def _ps(pid: int, columns: tuple[str, ...], timeout: float) -> str:
    # "name=" on every column suppresses the header line.
    return subprocess.run(
        ["ps", "-o", ",".join(f"{c}=" for c in columns), "-p", str(pid)],
        capture_output=True, text=True, timeout=max(timeout, _MIN_PS_TIMEOUT), check=False,
    ).stdout.strip()


def process_info(pid: int, timeout: float) -> tuple[int, str, str] | None:
    """(parent pid, command name, full command line) of `pid`, or None if it is gone.

    The command line is only fetched for `node`, the one case that needs it.
    """
    try:
        parts = _ps(pid, ("ppid", "comm"), timeout).split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            return None
        command = parts[1]
        args = _ps(pid, ("args",), timeout) if os.path.basename(command) == "node" else command
    except (OSError, subprocess.SubprocessError):
        return None
    return int(parts[0]), command, args


def is_claude(command: str, args: str) -> bool:
    """The native `claude` binary, or a Node install running the Claude Code CLI.

    The native binary is usually started through the `claude` link; started by its real path
    it shows as `.../claude/versions/<version>`. For Node, an npm install runs `.../@anthropic-ai/claude-code/cli.js` and a global shim
    runs `.../bin/claude`. A false match only ties the marker to the wrong long-lived parent,
    which then still dies with the terminal, so a loose check is acceptable here.
    """
    if os.path.basename(command) == "claude" or "/claude/versions/" in command:
        return True
    return os.path.basename(command) == "node" and ("claude-code" in args or "/claude " in f"{args} ")


def find_claude_pid(start: int) -> int | None:
    deadline = time.monotonic() + _WALK_DEADLINE_SECONDS
    pid = start
    for _ in range(_MAX_HOPS):
        remaining = deadline - time.monotonic()
        if pid <= 1 or remaining <= 0:
            return None
        info = process_info(pid, remaining)
        if info is None:
            return None
        parent, command, args = info
        if is_claude(command, args):
            return pid
        pid = parent
    return None


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def cached_pid(path: Path) -> int | None:
    """The owner recorded by an earlier event of this session, while it still runs.

    PreToolUse fires on every tool call; this skips the process walk on all but the first.
    """
    try:
        pid = json.loads(path.read_text()).get("claude_pid")
    except (OSError, ValueError, AttributeError):
        return None
    return pid if isinstance(pid, int) and pid > 1 and pid_alive(pid) else None


def project_name(payload: dict) -> str | None:
    """The last part of the session's working directory, for "Claude finished in <name>"."""
    cwd = payload.get("cwd")
    if not isinstance(cwd, str):
        return None
    name = "".join(ch for ch in os.path.basename(cwd.rstrip("/")) if ch.isprintable())
    return name[:_MAX_PROJECT_NAME] or None


def write_marker(path: Path, state: str, claude_pid: int, project: str | None) -> None:
    # Only this user may read which projects are open; tighten a folder made before that rule.
    SESSIONS_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        os.chmod(SESSIONS_DIR, 0o700)
    except OSError:
        pass  # never let the tightening stop the marker write
    record: dict = {"state": state, "claude_pid": claude_pid, "updated_at": time.time()}
    if project:
        record["project"] = project
    data = json.dumps(record)
    fd, tmp = tempfile.mkstemp(dir=SESSIONS_DIR, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def state_for(payload: dict, event: str) -> str | None:
    if event in BUSY_EVENTS:
        return "busy"
    if event == STOP:
        return "idle"
    if event == NOTIFICATION:
        kind = payload.get("notification_type")
        if kind in WAITING_NOTIFICATIONS:
            return "waiting"
        if kind in IDLE_NOTIFICATIONS:
            return "idle"
    return None


def handle(payload: dict, start_pid: int) -> None:
    event = payload.get("hook_event_name")
    session_id = payload.get("session_id")
    if not isinstance(event, str) or not isinstance(session_id, str):
        return
    path = marker_path(session_id)
    if path is None:
        return

    if event == SESSION_END:
        path.unlink(missing_ok=True)
        return
    state = state_for(payload, event)
    if state is None:
        return

    claude_pid = cached_pid(path) or find_claude_pid(start_pid)
    if claude_pid is None:
        # No live owner to tie the marker to; Vigil would discard it anyway.
        return
    write_marker(path, state, claude_pid, project_name(payload))


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read(_MAX_STDIN))
        if isinstance(payload, dict):
            handle(payload, os.getppid())
    except Exception:  # noqa: BLE001 - a hook failure must never reach Claude
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

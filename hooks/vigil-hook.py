#!/usr/bin/env python3
"""Claude Code hook for Vigil: tells the menu bar app when Claude is working.

One script for every event. It writes one small marker file per Claude Code session:

  UserPromptSubmit, PreToolUse  -> state "busy"
  Stop                          -> state "idle"
  SessionEnd                    -> marker removed

The marker holds only the state, the pid of the owning `claude` process and a timestamp.
Nothing else from the hook payload (prompt text, tool input) is ever stored. Vigil treats a
marker as working only while that pid is alive, so a crashed or killed session cannot keep
the Mac awake.

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

BUSY_EVENTS = {"UserPromptSubmit", "PreToolUse"}
IDLE_EVENTS = {"Stop"}
END_EVENTS = {"SessionEnd"}

# Session ids are UUIDs; anything else is reduced to a safe file name.
_UNSAFE = re.compile(r"[^A-Za-z0-9_-]")
# Hooks run through a shell or two below `claude`; never walk further than this.
_MAX_HOPS = 12


def marker_path(session_id: str) -> Path | None:
    name = _UNSAFE.sub("", session_id)[:128]
    return SESSIONS_DIR / f"{name}.json" if name else None


def _parent_and_name(pid: int) -> tuple[int, str, str] | None:
    """(parent pid, command name, full command line) of `pid`, or None if it is gone."""
    try:
        out = subprocess.run(
            ["ps", "-o", "ppid=,comm=", "-p", str(pid)],
            capture_output=True, text=True, timeout=2, check=False,
        ).stdout.strip()
        args = subprocess.run(
            ["ps", "-o", "args=", "-p", str(pid)],
            capture_output=True, text=True, timeout=2, check=False,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    parts = out.split(None, 1)
    if len(parts) != 2 or not parts[0].isdigit():
        return None
    return int(parts[0]), parts[1], args


def is_claude(command: str, args: str) -> bool:
    """The native `claude` binary, or a Node install running the Claude Code CLI."""
    if os.path.basename(command) == "claude":
        return True
    return os.path.basename(command) == "node" and ("claude-code" in args or "/claude " in f"{args} ")


def find_claude_pid(start: int) -> int | None:
    pid = start
    for _ in range(_MAX_HOPS):
        if pid <= 1:
            return None
        info = _parent_and_name(pid)
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


def write_marker(path: Path, state: str, claude_pid: int) -> None:
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    data = json.dumps({"state": state, "claude_pid": claude_pid, "updated_at": time.time()})
    fd, tmp = tempfile.mkstemp(dir=SESSIONS_DIR, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(data)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def handle(payload: dict, start_pid: int) -> None:
    event = payload.get("hook_event_name")
    session_id = payload.get("session_id")
    if not isinstance(event, str) or not isinstance(session_id, str):
        return
    path = marker_path(session_id)
    if path is None:
        return

    if event in END_EVENTS:
        path.unlink(missing_ok=True)
        return
    if event in BUSY_EVENTS:
        state = "busy"
    elif event in IDLE_EVENTS:
        state = "idle"
    else:
        return

    claude_pid = cached_pid(path) or find_claude_pid(start_pid)
    if claude_pid is None:
        # No live owner to tie the marker to; Vigil would discard it anyway.
        return
    write_marker(path, state, claude_pid)


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read())
        if isinstance(payload, dict):
            handle(payload, os.getppid())
    except Exception:  # noqa: BLE001 - a hook failure must never reach Claude
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())

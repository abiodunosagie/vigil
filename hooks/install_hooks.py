#!/usr/bin/env python3
"""Adds (or removes) Vigil's hook in ~/.claude/settings.json.

Appends one entry per event and leaves every other hook untouched. Running it twice changes
nothing. Before the first change, the file is copied to settings.json.vigil-backup; later
runs keep that first copy.

Usage: install_hooks.py [--remove] [--settings PATH] [--command CMD]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

EVENTS = ("UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd")
DEFAULT_SETTINGS = Path.home() / ".claude" / "settings.json"
DEFAULT_COMMAND = "$HOME/.claude/hooks/vigil-hook.py"
# Each hook gets this long before Claude moves on; the script normally takes milliseconds.
TIMEOUT_SECONDS = 5


class Unsupported(Exception):
    """The settings file has a shape this script will not edit."""


def _is_ours(hook: object, command: str) -> bool:
    return isinstance(hook, dict) and hook.get("command") == command


def _hooks_table(settings: dict) -> dict:
    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise Unsupported('"hooks" is not an object')
    return hooks


def add(settings: dict, command: str) -> bool:
    """Adds the hook to every event that lacks it. True when something changed."""
    hooks = _hooks_table(settings)
    changed = False
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise Unsupported(f'"hooks.{event}" is not a list')
        present = any(
            _is_ours(h, command)
            for group in groups if isinstance(group, dict) and isinstance(group.get("hooks"), list)
            for h in group["hooks"]
        )
        if not present:
            groups.append({"hooks": [{"type": "command", "command": command, "timeout": TIMEOUT_SECONDS}]})
            changed = True
    return changed


def remove(settings: dict, command: str) -> bool:
    """Removes the hook everywhere; drops groups and events it leaves empty. True when changed."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return False
    changed = False
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                kept_groups.append(group)
                continue
            kept = [h for h in group["hooks"] if not _is_ours(h, command)]
            if len(kept) != len(group["hooks"]):
                changed = True
            if kept:
                kept_groups.append({**group, "hooks": kept})
        hooks[event] = kept_groups
        if not kept_groups:
            del hooks[event]
    return changed


def write_json(path: Path, data: dict) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".settings-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        if path.exists():
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS)
    parser.add_argument("--command", default=DEFAULT_COMMAND)
    args = parser.parse_args(argv)

    # Edit the real file behind a symlink, so the link itself survives.
    path: Path = args.settings.resolve()
    try:
        settings = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
        if not isinstance(settings, dict):
            raise Unsupported("it is not a JSON object")
        changed = remove(settings, args.command) if args.remove else add(settings, args.command)
    except (ValueError, Unsupported) as error:
        print(f"{path}: {error}; not touching it.", file=sys.stderr)
        return 1

    if not changed:
        print("Hooks already " + ("removed." if args.remove else "installed."))
        return 0
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        backup = path.with_name(path.name + ".vigil-backup")
        if path.exists() and not backup.exists():
            shutil.copy2(path, backup)
        write_json(path, settings)
    except OSError as error:
        print(f"Could not write {path}: {error.strerror or error}", file=sys.stderr)
        return 1
    print("Hooks " + ("removed from " if args.remove else "added to ") + str(path))
    return 0


if __name__ == "__main__":
    sys.exit(main())

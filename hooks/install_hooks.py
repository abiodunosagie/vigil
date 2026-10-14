#!/usr/bin/env python3
"""Adds (or removes) Vigil's hook in ~/.claude/settings.json.

Appends one entry per event and leaves every other hook untouched. Running it twice changes
nothing. A copy of the previous file is kept next to it as settings.json.vigil-backup.

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

EVENTS = ("UserPromptSubmit", "PreToolUse", "Stop", "SessionEnd")
DEFAULT_SETTINGS = Path.home() / ".claude" / "settings.json"
DEFAULT_COMMAND = "$HOME/.claude/hooks/vigil-hook.py"
# Each hook gets this long before Claude moves on; the script normally takes milliseconds.
TIMEOUT_SECONDS = 5


def _is_ours(hook: object, command: str) -> bool:
    return isinstance(hook, dict) and hook.get("command") == command


def add(settings: dict, command: str) -> bool:
    """Adds the hook to every event that lacks it. True when something changed."""
    hooks = settings.setdefault("hooks", {})
    changed = False
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        present = any(
            _is_ours(h, command)
            for group in groups if isinstance(group, dict)
            for h in group.get("hooks", [])
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
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        if path.exists():
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except OSError:
        Path(tmp).unlink(missing_ok=True)
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS)
    parser.add_argument("--command", default=DEFAULT_COMMAND)
    args = parser.parse_args(argv)

    path: Path = args.settings
    if path.exists():
        try:
            settings = json.loads(path.read_text())
        except ValueError:
            print(f"{path} is not valid JSON; not touching it.", file=sys.stderr)
            return 1
        if not isinstance(settings, dict):
            print(f"{path} is not a JSON object; not touching it.", file=sys.stderr)
            return 1
    else:
        settings = {}

    changed = remove(settings, args.command) if args.remove else add(settings, args.command)
    if not changed:
        print("Hooks already " + ("removed." if args.remove else "installed."))
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + ".vigil-backup"))
    write_json(path, settings)
    print("Hooks " + ("removed from " if args.remove else "added to ") + str(path))
    return 0


if __name__ == "__main__":
    sys.exit(main())

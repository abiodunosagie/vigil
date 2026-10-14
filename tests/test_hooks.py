"""Tests for the Vigil hook and its installer. They never touch the real settings or markers."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


def _load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "hooks" / file)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


hook = _load("vigil_hook", "vigil-hook.py")
installer = _load("install_hooks", "install_hooks.py")


@pytest.fixture(autouse=True)
def sessions(tmp_path, monkeypatch):
    folder = tmp_path / "sessions"
    monkeypatch.setattr(hook, "SESSIONS_DIR", folder)
    return folder


@pytest.fixture
def owner(monkeypatch):
    """A live Claude owner with pid 4242 for every hook call."""
    monkeypatch.setattr(hook, "find_claude_pid", lambda start: 4242)
    monkeypatch.setattr(hook, "pid_alive", lambda pid: True)


def _marker(folder: Path, session: str = "abc-123") -> dict:
    return json.loads((folder / f"{session}.json").read_text())


# The hook ------------------------------------------------------------------


def test_prompt_marks_busy_with_owner_pid(sessions, owner):
    hook.handle({"hook_event_name": "UserPromptSubmit", "session_id": "abc-123", "prompt": "secret"}, 1)
    marker = _marker(sessions)
    assert marker["state"] == "busy"
    assert marker["claude_pid"] == 4242
    assert set(marker) == {"state", "claude_pid", "updated_at", "turn_started", "tools"}  # no cwd, so no project
    assert "secret" not in (sessions / "abc-123.json").read_text()


def test_stop_marks_idle_and_session_end_removes(sessions, owner):
    hook.handle({"hook_event_name": "PreToolUse", "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "Stop", "session_id": "abc-123"}, 1)
    assert _marker(sessions)["state"] == "idle"
    hook.handle({"hook_event_name": "SessionEnd", "session_id": "abc-123"}, 1)
    assert not (sessions / "abc-123.json").exists()


def test_session_end_without_marker_is_fine(sessions):
    hook.handle({"hook_event_name": "SessionEnd", "session_id": "nothing-here"}, 1)


def test_no_claude_owner_writes_nothing(sessions, monkeypatch):
    monkeypatch.setattr(hook, "find_claude_pid", lambda start: None)
    hook.handle({"hook_event_name": "UserPromptSubmit", "session_id": "abc-123"}, 1)
    assert not sessions.exists() or not any(sessions.iterdir())


def test_post_tool_use_marks_busy_again(sessions, owner):
    hook.handle({"hook_event_name": "Stop", "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "PostToolUse", "session_id": "abc-123"}, 1)
    assert _marker(sessions)["state"] == "busy"


@pytest.mark.parametrize("kind", ["permission_prompt", "elicitation_dialog"])
def test_questions_mark_waiting(sessions, owner, kind):
    hook.handle({"hook_event_name": "PreToolUse", "session_id": "abc-123"}, 1)
    payload = {"hook_event_name": "Notification", "session_id": "abc-123", "message": "secret",
               "notification_type": kind}
    hook.handle(payload, 1)
    assert _marker(sessions)["state"] == "waiting"
    assert "secret" not in (sessions / "abc-123.json").read_text()


def test_idle_prompt_marks_idle(sessions, owner):
    hook.handle({"hook_event_name": "PreToolUse", "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "Notification", "session_id": "abc-123", "notification_type": "idle_prompt"}, 1)
    assert _marker(sessions)["state"] == "idle"


@pytest.mark.parametrize("kind", ["auth_success", "something_new", None])
def test_other_notifications_leave_the_state(sessions, owner, kind):
    hook.handle({"hook_event_name": "PreToolUse", "session_id": "abc-123"}, 1)
    payload = {"hook_event_name": "Notification", "session_id": "abc-123"}
    if kind:
        payload["notification_type"] = kind
    hook.handle(payload, 1)
    assert _marker(sessions)["state"] == "busy"


def test_project_is_the_folder_name_only(sessions, owner):
    hook.handle({"hook_event_name": "PreToolUse", "session_id": "abc-123",
                 "cwd": "/Users/me/Projects/tools/vigil/", "tool_input": {"command": "secret"}}, 1)
    marker = _marker(sessions)
    assert set(marker) == {"state", "claude_pid", "updated_at", "turn_started", "tools", "project"}
    assert marker["project"] == "vigil"
    text = (sessions / "abc-123.json").read_text()
    assert "Users" not in text and "Projects" not in text
    assert "secret" not in text


@pytest.mark.parametrize("cwd, expected", [
    ("/", None), ("", None), (5, None), ("/a/" + "x" * 200, "x" * 80), ("/a/b\x07c", "bc"),
])
def test_project_name_edge_cases(cwd, expected):
    assert hook.project_name({"cwd": cwd}) == expected


def test_project_name_without_cwd():
    assert hook.project_name({}) is None


def test_sessions_folder_is_private_when_new_and_when_old(sessions, owner):
    hook.handle({"hook_event_name": "Stop", "session_id": "abc-123"}, 1)
    assert sessions.stat().st_mode & 0o777 == 0o700
    sessions.chmod(0o755)
    hook.handle({"hook_event_name": "Stop", "session_id": "abc-123"}, 1)
    assert sessions.stat().st_mode & 0o777 == 0o700


def test_large_payload_still_parses(sessions, owner, monkeypatch):
    big = json.dumps({"hook_event_name": "PostToolUse", "session_id": "abc-123", "tool_response": "x" * (3 << 20)})
    monkeypatch.setattr(sys, "stdin", io.StringIO(big))
    monkeypatch.setattr(os, "getppid", lambda: 1)
    assert hook.main() == 0
    assert _marker(sessions)["state"] == "busy"


def test_other_events_and_bad_payloads_are_ignored(sessions, monkeypatch):
    monkeypatch.setattr(hook, "find_claude_pid", lambda start: 4242)
    hook.handle({"hook_event_name": "SubagentStop", "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "Stop"}, 1)
    hook.handle({"hook_event_name": 5, "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "Stop", "session_id": ["x"]}, 1)
    assert not sessions.exists() or not any(sessions.iterdir())


def test_session_id_cannot_escape_the_folder(sessions, owner):
    hook.handle({"hook_event_name": "Stop", "session_id": "../../evil"}, 1)
    assert [p.name for p in sessions.iterdir()] == ["evil.json"]
    # Nothing but dots and slashes leaves no name at all, so nothing is written.
    hook.handle({"hook_event_name": "Stop", "session_id": "../.."}, 1)
    assert [p.name for p in sessions.iterdir()] == ["evil.json"]


def test_cached_owner_skips_the_walk_while_alive(sessions, monkeypatch):
    calls = []
    monkeypatch.setattr(hook, "find_claude_pid", lambda start: calls.append(start) or 4242)
    monkeypatch.setattr(hook, "pid_alive", lambda pid: True)
    hook.handle({"hook_event_name": "UserPromptSubmit", "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "PreToolUse", "session_id": "abc-123"}, 1)
    assert len(calls) == 1


def test_turn_counts_tool_calls_and_resets_on_prompt(sessions, owner, monkeypatch):
    clock = iter([100.0, 101.0, 102.0, 103.0, 200.0, 201.0])
    monkeypatch.setattr(hook.time, "time", lambda: next(clock))
    hook.handle({"hook_event_name": "UserPromptSubmit", "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "PreToolUse", "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "PostToolUse", "session_id": "abc-123"}, 1)
    hook.handle({"hook_event_name": "PreToolUse", "session_id": "abc-123"}, 1)
    marker = _marker(sessions)
    assert (marker["turn_started"], marker["tools"]) == (100.0, 2)
    hook.handle({"hook_event_name": "Stop", "session_id": "abc-123"}, 1)
    assert (_marker(sessions)["turn_started"], _marker(sessions)["tools"]) == (100.0, 2)
    hook.handle({"hook_event_name": "UserPromptSubmit", "session_id": "abc-123"}, 1)
    assert (_marker(sessions)["turn_started"], _marker(sessions)["tools"]) == (201.0, 0)


def test_turn_counters_start_now_without_history():
    assert hook.turn_counters({}, "PreToolUse", 50.0) == (50.0, 1)
    assert hook.turn_counters({"turn_started": "x", "tools": 3}, "Stop", 50.0) == (50.0, 0)
    assert hook.turn_counters({"turn_started": 10, "tools": 3}, "PreToolUse", 50.0) == (10.0, 4)


def test_dead_cached_owner_is_looked_up_again(sessions, monkeypatch):
    sessions.mkdir()
    (sessions / "abc-123.json").write_text(json.dumps({"state": "idle", "claude_pid": 999, "updated_at": 0}))
    monkeypatch.setattr(hook, "pid_alive", lambda pid: False)
    monkeypatch.setattr(hook, "find_claude_pid", lambda start: 4242)
    hook.handle({"hook_event_name": "UserPromptSubmit", "session_id": "abc-123"}, 1)
    assert _marker(sessions)["claude_pid"] == 4242


def test_corrupt_marker_is_replaced(sessions, monkeypatch):
    sessions.mkdir()
    (sessions / "abc-123.json").write_text("{not json")
    monkeypatch.setattr(hook, "find_claude_pid", lambda start: 4242)
    hook.handle({"hook_event_name": "UserPromptSubmit", "session_id": "abc-123"}, 1)
    assert _marker(sessions)["state"] == "busy"


def test_is_claude_matches_native_and_node_installs():
    assert hook.is_claude("claude", "claude")
    assert hook.is_claude("/Users/me/.local/bin/claude", "claude --resume")
    assert hook.is_claude("/Users/me/.local/share/claude/versions/2.1.299", "2.1.299")
    assert hook.is_claude("node", "node /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js")
    assert not hook.is_claude("zsh", "-zsh")
    assert not hook.is_claude("node", "node server.js")


def test_walk_finds_claude_through_shells(monkeypatch):
    tree = {50: (40, "/bin/sh", "sh -c hook"), 40: (30, "/bin/zsh", "zsh"), 30: (1, "claude", "claude")}
    monkeypatch.setattr(hook, "process_info", lambda pid, timeout: tree.get(pid))
    assert hook.find_claude_pid(50) == 30
    assert hook.find_claude_pid(40) == 30
    assert hook.find_claude_pid(99) is None


def test_walk_stops_at_launchd(monkeypatch):
    tree = {50: (1, "/bin/sh", "sh")}
    monkeypatch.setattr(hook, "process_info", lambda pid, timeout: tree.get(pid))
    assert hook.find_claude_pid(50) is None


def test_walk_gives_up_at_the_deadline(monkeypatch):
    clock = iter([0.0, 0.0, 1.0, 2.0, 3.0])
    monkeypatch.setattr(hook.time, "monotonic", lambda: next(clock))
    tree = {50: (40, "sh", "sh"), 40: (30, "sh", "sh"), 30: (1, "claude", "claude")}
    monkeypatch.setattr(hook, "process_info", lambda pid, timeout: tree.get(pid))
    assert hook.find_claude_pid(50) is None


def test_process_info_reads_this_process():
    info = hook.process_info(os.getpid(), 2)
    assert info is not None and info[0] == os.getppid()


def test_main_never_fails_and_prints_nothing(monkeypatch, capsys):
    monkeypatch.setattr(sys, "stdin", io.StringIO("not json"))
    assert hook.main() == 0
    monkeypatch.setattr(sys, "stdin", io.StringIO("[1, 2]"))
    assert hook.main() == 0
    assert capsys.readouterr() == ("", "")


def test_script_runs_standalone_outside_claude(tmp_path):
    # Run as a real process with a throwaway HOME: it must exit 0 and print nothing.
    env = {**os.environ, "HOME": str(tmp_path)}
    result = subprocess.run(
        [sys.executable, str(ROOT / "hooks" / "vigil-hook.py")],
        input=json.dumps({"hook_event_name": "Stop", "session_id": "s1"}),
        capture_output=True, text=True, env=env, check=False,
    )
    assert result.returncode == 0
    assert result.stdout == "" and result.stderr == ""


# The installer -------------------------------------------------------------

CMD = "$HOME/.claude/hooks/vigil-hook.py"


def _existing() -> dict:
    return {
        "model": "opus",
        "hooks": {
            "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "router.py"}]}],
            "Stop": [{"hooks": [{"type": "command", "command": "verify.py"}]}],
        },
    }


def test_add_appends_without_touching_other_hooks():
    settings = _existing()
    assert installer.add(settings, CMD)
    hooks = settings["hooks"]
    assert hooks["UserPromptSubmit"][0] == {"hooks": [{"type": "command", "command": "router.py"}]}
    assert hooks["Stop"][0] == {"hooks": [{"type": "command", "command": "verify.py"}]}
    for event in installer.EVENTS:
        assert hooks[event][-1]["hooks"][0]["command"] == CMD
    assert settings["model"] == "opus"


def test_add_is_idempotent():
    settings = _existing()
    installer.add(settings, CMD)
    snapshot = json.dumps(settings)
    assert not installer.add(settings, CMD)
    assert json.dumps(settings) == snapshot


def test_remove_restores_the_original():
    settings = _existing()
    installer.add(settings, CMD)
    assert installer.remove(settings, CMD)
    assert settings == _existing()
    assert not installer.remove(settings, CMD)


def test_main_round_trip_on_a_file(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps(_existing(), indent=2) + "\n")
    original = path.read_text()
    assert installer.main(["--settings", str(path)]) == 0
    assert (tmp_path / "settings.json.vigil-backup").read_text() == original
    assert installer.main(["--settings", str(path)]) == 0
    assert installer.main(["--settings", str(path), "--remove"]) == 0
    assert path.read_text() == original


def test_backup_keeps_the_first_original(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps(_existing(), indent=2) + "\n")
    original = path.read_text()
    installer.main(["--settings", str(path)])
    installer.main(["--settings", str(path), "--remove"])
    installer.main(["--settings", str(path)])
    assert (tmp_path / "settings.json.vigil-backup").read_text() == original


@pytest.mark.parametrize("hooks", [[], {"Stop": {"hooks": []}}, "nope"])
def test_unusual_shapes_are_refused_untouched(tmp_path, hooks):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"hooks": hooks}))
    before = path.read_text()
    assert installer.main(["--settings", str(path)]) == 1
    assert path.read_text() == before


def test_group_with_null_hooks_is_kept(tmp_path):
    settings = {"hooks": {"Stop": [{"hooks": None}]}}
    assert installer.add(settings, CMD)
    assert settings["hooks"]["Stop"][0] == {"hooks": None}


def test_symlinked_settings_stay_a_symlink(tmp_path):
    real = tmp_path / "real.json"
    real.write_text(json.dumps(_existing()))
    link = tmp_path / "settings.json"
    link.symlink_to(real)
    assert installer.main(["--settings", str(link)]) == 0
    assert link.is_symlink()
    assert CMD in real.read_text()


def test_main_refuses_invalid_json(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text("{oops")
    assert installer.main(["--settings", str(path)]) == 1
    assert path.read_text() == "{oops"

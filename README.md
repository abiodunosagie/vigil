# Vigil

A macOS menu bar app that keeps your Mac awake while any Claude Code session is on a task,
tells you when Claude finishes or needs you, and lets the Mac sleep on its usual schedule once
every session is done.

## How it works

- A small Claude Code hook (`hooks/vigil-hook.py`) runs on `UserPromptSubmit`, `PreToolUse`,
  `PostToolUse`, `Notification`, `Stop` and `SessionEnd`. It writes one marker per session to
  `~/Library/Application Support/Vigil/sessions/` (readable only by you) with up to four
  fields: the state (`busy`, `waiting` or `idle`), the pid of the owning `claude` process, a
  timestamp, and the name of the session's project folder when Claude Code sends it. Prompt
  text, tool input and output, and messages are never stored.
- The app reads those markers every few seconds. While any session is busy or waiting and its
  `claude` process is alive, it holds a `PreventUserIdleSystemSleep` power assertion. The
  screen can still dim and sleep; the Mac itself stays up.
- When the last session stops, Vigil holds on for the grace time, 60 seconds by default (a
  Stop hook can send Claude straight back to work), then releases. From there macOS sleeps on
  your own Energy settings.
- When Claude asks you something mid task (a permission prompt or a question), the session
  counts as waiting: the Mac stays awake, because your answer usually starts a command that
  fires no hook until it finishes.
- A session only counts while its owner is still a running `claude` process. Markers whose
  process has died are deleted, so a crashed or closed session does not keep the Mac awake.
- Claude Code fires no hook when you interrupt a turn with Esc. Every tool call refreshes the
  marker, so a busy or waiting marker not refreshed for 45 minutes stops holding the Mac. Such a
  session shows as "quiet", and is reported as finished only if Claude later stops on its own.

## Notifications

- **Claude finished:** a session that did work has stayed idle for 20 seconds (so a Stop hook
  sending Claude straight back to work is not reported), or a working session ended on its
  own. The text gives the task length and tool calls: "Done in vigil, 14 min, 38 commands."
  Closing the terminal or killing `claude` mid task is not reported as finished. Click it to
  bring that session's Terminal tab to the front (Terminal.app; macOS asks once to allow it).
- **Claude needs you:** a session asked a permission question or another question.
- **All Claude sessions are done:** the session hold is released.
- **Battery low, Vigil let go:** on battery below your floor, every hold is dropped.

Each kind has its own sound (Settings). Mute turns all sounds off; quiet hours turn them off
for a time range while banners still show. macOS asks once whether Vigil may show
notifications; click Allow.

## More holds and switches

- **Running commands:** a Bash command Claude started in the background keeps the Mac held
  after Claude's turn ends ("running a command" in the panel), until it exits.
- **Grace time:** stay awake 1, 5, 15 or 30 minutes after the last session finishes.
- **Keep screen on:** also stops the screen dimming and locking while held.
- **Manual hold:** keep the Mac awake for 30 minutes to 4 hours, or until turned off, with
  no Claude session.
- **Battery guard:** on battery below a floor you set (20% by default), every hold lets go.
- **Lid closed:** optional root helper (`lid/vigil-lid.sh`), installed from Settings with your
  admin password. While held and switched on, the Mac keeps running with the lid shut. It
  only reads the age of a heartbeat file Vigil refreshes; if Vigil quits, crashes or stops
  holding, normal lid sleep is back within about a minute. Below 10% on battery it always
  lets the Mac sleep. Remove it from Settings. If you ever delete its files by hand while it
  holds, put lid sleep back with `sudo pmset -a disablesleep 0`. It never takes over a
  `disablesleep` setting you made yourself.
- **Phone alerts:** the same alerts through ntfy (free app, no account). Settings shows a long
  random topic; subscribe to it in the ntfy app. Anyone who knows the topic can read the
  alerts, so keep it private; "New topic" replaces it. Only the alert title and text are sent.
  Pushover is a paid alternative if you ever prefer one.
- **Today:** the panel shows today's finished tasks, total working time and the longest task,
  from a daily log in `~/Library/Application Support/Vigil/log/` kept 30 days.

## Desktop widget

Small and medium sizes: whether the Mac is held and for how long, the open sessions with their
state, and today's total. Add it from the widget gallery (right click the desktop, Edit
Widgets, search Vigil). The app refreshes it on every change.

Check the hold any time with `pmset -g assertions | grep Vigil`.

## Menu bar

- Click the icon: status, every open Claude session with its project and state, today's
  total, the manual hold, Keep screen on, Mute, Launch at login, Settings and Quit.
- Right click or Control click: Open Vigil, Settings and Quit Vigil.
- Icon: a filled cup while Claude works, an outline cup during the grace time, a moon when
  the Mac can sleep. With more than one session working, the count shows next to it.

## Requirements

Apple Silicon Mac, macOS 15 or later, Xcode command line tools, Python 3, Claude Code.

## Install

```sh
./build-app.sh
open ~/Applications/Vigil.app
```

The script builds `~/Applications/Vigil.app`, copies the hook to `~/.claude/hooks/`, and adds
it to `~/.claude/settings.json` without touching your other hooks. Before its first change it
copies your original file to `settings.json.vigil-backup` and never overwrites that copy, so
it is a pre-Vigil snapshot, not a rolling backup. The first launch turns on Launch at login.

To move the icon in the menu bar, hold Command and drag it.

Remove the hook: `python3 hooks/install_hooks.py --remove`.

## Limits

- Closing the lid sleeps the Mac unless the lid helper is installed and switched on.
- Jumping to a session covers Terminal.app only, not iTerm or editors.
- The widget's placement is yours: macOS has no way for an app to put it on the desktop.

## Tests

```sh
python3 -m pytest tests
tests/run-swift-tests.sh
```

MIT licensed.

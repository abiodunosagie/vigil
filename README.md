# Vigil

A macOS menu bar app that keeps your Mac awake while Claude Code is working, and lets it sleep
on its usual schedule once Claude is done.

## How it works

- A small Claude Code hook (`hooks/vigil-hook.py`) runs on `UserPromptSubmit`, `PreToolUse`,
  `PostToolUse`, `Notification`, `Stop` and `SessionEnd`. It writes one marker per session to
  `~/Library/Application Support/Vigil/sessions/` with only three fields: the state
  (`busy` or `idle`), the pid of the owning `claude` process, and a timestamp. Prompt text and
  tool input are never stored.
- The app reads those markers every few seconds. While any session is busy and its `claude`
  process is alive, it holds a `PreventUserIdleSystemSleep` power assertion. The screen can
  still dim and sleep; the Mac itself stays up.
- When the last session stops, Vigil holds on for 60 more seconds (a Stop hook can send Claude
  straight back to work), then releases. From there macOS sleeps on your own Energy settings.
- When Claude stops to wait on you (a permission prompt or a question), the session counts as
  idle until you answer.
- A session only counts while its owner is still a running `claude` process. Markers whose
  process has died are deleted, so a crashed or closed session does not keep the Mac awake.
- Claude Code fires no hook when you interrupt a turn with Esc. Every tool call refreshes the
  marker, so a busy marker not refreshed for 20 minutes is treated as idle.

Check it any time with `pmset -g assertions | grep Vigil`.

## Menu bar

- Click the icon: status, open and working session counts, how long it has been holding,
  Launch at login, and Quit.
- Right click or Control click: Open Vigil and Quit Vigil.
- Icon: a filled cup while Claude works, an outline cup during the 60 second grace, a moon when
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
copies your original file to `settings.json.vigil-backup` and never overwrites that copy. The first launch turns on Launch at login.

To move the icon in the menu bar, hold Command and drag it.

Remove the hook: `python3 hooks/install_hooks.py --remove`.

## Limits

- Closing the lid still sleeps the Mac. Preventing that needs root (`pmset disablesleep`),
  which Vigil does not do.
- A Bash command Claude starts in the background keeps running after Claude's turn ends. Vigil
  sees the session as finished at that point, so after the grace period the Mac may sleep
  before that background command completes.

## Tests

```sh
python3 -m pytest tests
```

MIT licensed.

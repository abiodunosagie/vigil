# Vigil

A macOS menu bar app that keeps your Mac awake while Claude Code is working, and lets it sleep
on its usual schedule once Claude is done.

## How it works

- A small Claude Code hook (`hooks/vigil-hook.py`) runs on `UserPromptSubmit`, `PreToolUse`,
  `Stop` and `SessionEnd`. It writes one marker per session to
  `~/Library/Application Support/Vigil/sessions/` with only three fields: the state
  (`busy` or `idle`), the pid of the owning `claude` process, and a timestamp. Prompt text and
  tool input are never stored.
- The app reads those markers every few seconds. While any session is busy and its `claude`
  process is alive, it holds a `PreventUserIdleSystemSleep` power assertion. The screen can
  still dim and sleep; the Mac itself stays up.
- When the last session stops, Vigil holds on for 60 more seconds (a Stop hook can send Claude
  straight back to work), then releases. From there macOS sleeps on your own Energy settings.
- Markers whose `claude` process has died are deleted, so a crashed session never keeps the
  Mac awake.

Check it any time with `pmset -g assertions | grep Vigil`.

## Menu bar

- Click the icon: status, open and working session counts, how long it has been holding,
  Launch at login, and Quit.
- Right click or Control click: Open Vigil and Quit Vigil.
- Icon: a filled cup while Claude works, an outline cup during the 60 second grace, a moon when
  the Mac can sleep. With more than one session working, the count shows next to it.

## Install

```sh
./build-app.sh
open ~/Applications/Vigil.app
```

The script builds `~/Applications/Vigil.app`, copies the hook to `~/.claude/hooks/`, and adds
it to `~/.claude/settings.json` without touching your other hooks (a backup is kept as
`settings.json.vigil-backup`). The first launch turns on Launch at login.

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

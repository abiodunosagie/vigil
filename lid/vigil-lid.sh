#!/bin/sh
# Vigil lid helper. Runs as root every 15 seconds (launchd StartInterval).
#
# Keeps the Mac awake with the lid closed (pmset disablesleep 1) only while Vigil keeps the
# heartbeat file fresh. If Vigil quits, crashes or stops holding, the heartbeat goes stale and
# the next run puts normal lid sleep back. It reads nothing from the heartbeat but its age,
# and it only ever undoes a setting it made itself (its state file says so), so a setting the
# user made by hand is left alone.
#
# Usage: vigil-lid.sh <heartbeat file>     (the path is fixed in the root-owned launchd plist)
#        vigil-lid.sh --restore            (put lid sleep back now, used on uninstall)

STATE="/Library/Application Support/VigilLid/held"
MAX_AGE=45
BATTERY_FLOOR=10

restore() {
    if [ -f "$STATE" ]; then
        /usr/bin/pmset -a disablesleep 0
        /bin/rm -f "$STATE"
    fi
}

if [ "$1" = "--restore" ]; then
    restore
    exit 0
fi

HEART="$1"
fresh=0
if [ -n "$HEART" ] && [ -f "$HEART" ] && [ ! -L "$HEART" ]; then
    modified=$(/usr/bin/stat -f %m "$HEART" 2>/dev/null)
    now=$(/bin/date +%s)
    case "$modified" in
        ''|*[!0-9]*) ;;
        *) [ $((now - modified)) -lt "$MAX_AGE" ] && fresh=1 ;;
    esac
fi

# Never keep a nearly empty Mac running in a closed bag, whatever Vigil says.
battery=$(/usr/bin/pmset -g batt)
if echo "$battery" | /usr/bin/grep -q "Battery Power"; then
    percent=$(echo "$battery" | /usr/bin/grep -Eo '[0-9]+%' | /usr/bin/head -1 | /usr/bin/tr -d '%')
    case "$percent" in
        ''|*[!0-9]*) fresh=0 ;;
        *) [ "$percent" -le "$BATTERY_FLOOR" ] && fresh=0 ;;
    esac
fi

if [ "$fresh" = 1 ]; then
    if [ ! -f "$STATE" ]; then
        /bin/mkdir -p "/Library/Application Support/VigilLid"
        /usr/bin/pmset -a disablesleep 1 && /usr/bin/touch "$STATE"
    fi
else
    restore
fi

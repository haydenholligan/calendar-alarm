#!/bin/sh
# Remove Calendar Alarm: background agent, app, saved state and the Calendar permission.
# Calendar events are never modified, so there is nothing to undo there.
set -eu

app="${1:-/Applications/Calendar Alarm.app}"
support="$HOME/Library/Application Support/com.corseapps.calendaralarm"

if [ -x "$app/Contents/MacOS/CalendarAlarm" ]; then
    "$app/Contents/MacOS/CalendarAlarm" --disable || true
fi
rm -rf "$app" "$support"
tccutil reset Calendar com.corseapps.calendaralarm >/dev/null 2>&1 || true
echo "Removed Calendar Alarm."

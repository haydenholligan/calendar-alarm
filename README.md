# Calendar Alarm

A full-screen, ringing alarm for your macOS Calendar events, with **no app running in the background**.

Calendar Alarm reads the calendars already synced into macOS Calendar (iCloud, Google, Exchange, local) and rings a full-screen alarm a few minutes before each event. The sound loops until you press **Dismiss**, **Snooze**, or **Join**.

Between checks nothing of Calendar Alarm stays in memory. There is no menu-bar icon, login item process, or helper. A LaunchAgent starts a short check once a minute. The check reads upcoming events and then exits. If an alarm is due before the next check, that same process waits, checks the event again, and rings.

## Requirements

- macOS 14 or later. Tested so far only on macOS 26.5 (MacBook Air, Apple Silicon).
- Xcode 16 or later to build.
- An Apple Development (or Developer ID) signing identity in your keychain. Calendar permission is tied to the code signature, so ad-hoc builds lose access on every rebuild.

## Install from source

```sh
git clone https://github.com/haydenholligan/calendar-alarm
cd calendar-alarm
make install          # builds, signs and copies to /Applications
open "/Applications/Calendar Alarm.app"
```

In the window that opens:

1. **Grant Calendar Access…**, then **Allow**.
2. Tick **Ring alarms in the background**. If macOS asks, approve it under System Settings › General › Login Items.
3. **Test Background Alarm in 1 Minute**, then quit. The alarm should appear within a minute.

Calendar accounts must already be added in System Settings › Internet Accounts or in Calendar. Calendar Alarm never talks to iCloud, Google, or Microsoft directly, and never changes your events.

## Defaults

- All calendars, timed events only. All-day and declined events are skipped.
- One alarm 5 minutes before start. Multiple lead times can be set in `config.json` (for example `"leadMinutes": [5, 0]`).
- Snooze for 1, 5, or 10 minutes. **Join** appears for Zoom, Google Meet, and Teams links.
- Alarms missed by more than 5 minutes (asleep, logged out) are skipped, not replayed.

Config: `~/Library/Application Support/com.corseapps.calendaralarm/config.json`. It holds `disabledCalendarIDs`, `leadMinutes`, `graceMinutes`, `skipAllDay`, and `skipDeclined`.

## Command line

```sh
app="/Applications/Calendar Alarm.app/Contents/MacOS/CalendarAlarm"
"$app" --status       # agent state, last check, next alarm, measured cost per check
"$app" --test-in 60   # ask the background check to ring a test alarm in 60 s
"$app" --enable       # register the LaunchAgent (the settings window does this too)
"$app" --disable
```

`--status` shows what the last background check recorded. It doesn't query Calendar itself, because from Terminal macOS attributes Calendar access to the terminal app.

## Limitations

- **It can't ring while the Mac is asleep, shut down, or logged out.** After waking, alarms within the 5-minute grace window ring. Older ones are skipped.
- Events have to reach macOS Calendar first. Upstream sync delays from iCloud, Google, or Exchange are outside its control.
- If the screen is locked, the sound plays but the window only appears after you unlock. Muted output or missing speakers silence it; the window still shows.
- "Nothing in the background" means no Calendar Alarm process between checks. It does not mean zero cost. A check runs every minute; `--status` reports the measured CPU and memory per check.
- Not sandboxed and not on the App Store.

## Uninstall

```sh
make uninstall
```

This removes the LaunchAgent, the app, the saved state, and the Calendar permission. Your calendar events are never modified.

## Privacy

Event data stays on your Mac. There is no network access, no analytics, and no crash reporting. Saved state holds opaque hashed keys and timestamps only, never event titles, notes, or attendees.

## Development

```sh
make test   # swift test: planner, snooze, dedupe, link detection, storage
make app    # build and sign build/Calendar Alarm.app
```

See `docs/feasibility.md` for what was verified on real hardware and how.

## License

MIT

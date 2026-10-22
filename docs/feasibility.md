# Feasibility (M0)

Spikes run on 2026-10-21. Everything below was observed on real hardware unless marked **not yet tested**.

**Machine:** MacBook Air (Mac15,12, Apple Silicon), macOS 26.5 (25F71), Xcode 26.6, Swift 6.3.3.
**Build:** signed with an Apple Development certificate, hardened runtime, `com.apple.security.personal-information.calendars` entitlement, installed at `/Applications/Calendar Alarm.app`. Not sandboxed.

## Design chosen: one static agent that rings itself

The original spec preferred one launchd job per alarm. We chose a simpler design instead. A single static LaunchAgent, bundled at `Contents/Library/LaunchAgents/com.corseapps.calendaralarm.sync.plist` and registered with `SMAppService.agent(plistName:)`, runs `CalendarAlarm --sync` every 60 s (`StartInterval` 60, `RunAtLoad`, no `KeepAlive`). Each run:

1. Reads events from now − 6 h to now + 2 h with a fresh `EKEventStore`.
2. Plans alarms with pure code (`CalendarAlarmCore.Planner`).
3. Exits if nothing is due in the next 75 s.
4. Otherwise sleeps until the alarm, reads the events again to confirm it, and rings in the same process.

With this design there are no dynamic plists, no `launchctl` calls, no job manifest, no `StartCalendarInterval` year problem, and no orphaned jobs. The cost is about 1,440 short runs a day. If the measured energy cost turns out to be too high, the fallback is a single rewritten "next alarm" job.

## Spike A: EventKit from a launchd-started process — PASS

- The user granted Calendar access by clicking **Grant Calendar Access…** in the settings window (`requestFullAccessToEvents()`).
- After that, the agent-started `--sync` process recorded `calendar access: full access` and read events from two calendars, one of them iCloud.
- No Terminal access was involved. The grant belongs to the bundle identity because the agent runs the bundle's own signed executable (`BundleProgram`), the same binary as the settings window. No second grant was needed.
- Caveat: when the binary is launched from a terminal, macOS attributes Calendar access to the terminal app. `--status` therefore reports the state recorded by the agent instead of asking EventKit itself. The `--events` diagnostic must be launched through LaunchServices: `open -W -a "Calendar Alarm" --stdout out.txt --args --events`.

## Spike B: ringing alarm with no resident process — PASS (awake, unlocked)

| Alarm | Scheduled | Rang (ledger) |
|---|---|---|
| Test alarm (`Test Background Alarm in 1 Minute`) | ~17:43:20Z | 17:43:21Z |
| Real event 13:50 local, 1-min lead | 17:49:00Z | 17:49:00Z |
| Snooze 1 min of the above | ~17:50:03Z | 17:50:04Z |
| Real event 14:00 local, 1-min lead | 17:59:00Z | 17:59:00Z |

- Each alarm showed a full-screen window and looped its sound until the user acted. The user confirmed that Dismiss and Snooze worked.
- No Calendar Alarm process existed before the waiting run started or after dismissal. Checked with `pgrep -x CalendarAlarm`.
- `launchctl print gui/<uid>/com.corseapps.calendaralarm.sync` shows `run interval = 60 seconds`, `state = not running` between runs, `last exit code = 0`, and no KeepAlive.
- Found and fixed: in light system appearance, buttons drew black text on the dark backdrop. The window is now forced to dark appearance.
- **Not yet tested:** a locked screen, an app in a full-screen Space, an external display, restart and login, sleep across an alarm, and simultaneous alarms on hardware (covered by unit tests only).

## Spike C: job management — replaced by design

Per-event job management is no longer needed. The one static agent registered with `SMAppService`. Status went to `enabled`, and the user saw no separate approval step during registration in this run.

### Moving, replacing and re-registering the app (Mac mini, macOS 26.5.1, ad-hoc signed)

| Change | Agent result | `SMAppService.status` |
|---|---|---|
| `make install` over the installed app, Apple Development signed (MacBook, several times) | Keeps running the new binary; Calendar access survives | `enabled` |
| App moved out of `/Applications` | Every run fails: `last exit code = 78: EX_CONFIG` | still `enabled` |
| Ad-hoc rebuild replaced in place | Every run fails with `EX_CONFIG` (the job carries a code requirement, `has LWCR`, and an ad-hoc requirement is the cdhash) | still `enabled` |
| `register()` again while enabled | No-op; still broken | `enabled` |
| `unregister()` then immediately `register()` in one process | Still broken | `enabled` |
| `unregister()`, wait until status is `notRegistered`, then `register()` | Repaired; next run exits 0 | `enabled` |

The fix is in `Agent.register(store:)`, called when Settings opens and by `--enable`. Each check records the bundle path and an executable identity (inode plus modification time). If either differs from the running app, or the last check is more than 150 s old, it re-registers using the wait-for-`notRegistered` sequence. It skips this when a check holds the run lock, because unregistering would kill a ringing alarm. Both the moved case and the ad-hoc rebuild case were broken on purpose and then repaired by a single `--enable`. There's no way to detect a moved app without something running, so the README tells users to open the app once after moving it.

`scripts/uninstall.sh` was verified on the mini. It turns the agent off, removes the app and state, and resets Calendar permission. Afterwards no job remains (`launchctl print` says `Bad request`) and no process remains.

## Cost of an idle check (app's own measurement)

Each `--sync` that exits without ringing records `getrusage` CPU time and `task_vm_info.ledger_phys_footprint_peak`:

| | Value |
|---|---|
| Idle runs measured | 13 |
| CPU per run | 35 ms avg |
| Wall time per run | 42 ms avg |
| Peak physical footprint | 4.1 MB max |

As a cross-check, `scripts/ram-monitor.py` caught one idle run live and `footprint` reported 4.0 MB peak, which agrees with the app's own reading. Extrapolating, 1,440 runs a day would be about 50 s of CPU per day. **This is an extrapolation, not a measurement.** The 24-hour monitor run below measured it.

### 24-hour monitor (MacBook Air, 2026-10-21 14:00 to 2026-10-22 14:00, normal use with sleep)

| | Value |
|---|---|
| Time with no Calendar Alarm process | 98.3 % |
| Time-weighted average footprint | 0.22 MB |
| Idle checks recorded by the app | 453, 38 ms CPU avg, 4.3 MB peak |
| Checks that waited for an alarm | 24, peak 4.0 MB |
| Ringing processes | 1, peak 15.0 MB |

The monitor flagged one waiting check that lived 105 s against its 80 s budget. It started one second before the Mac slept and stayed frozen until the next wake, so it used no CPU in that time.

The run found one bug. A noon alarm was planned during a lid-closed maintenance wake (DarkWake) and stayed up until the lid opened 22 minutes later. Alarms still on screen after a wake are now skipped if they are past the grace window.

## Build and tooling findings

- `codesign` fails with `errSecInternalComponent` from an SSH or `et` session, because the login keychain isn't reachable outside the GUI security session. Building inside the GUI session works, for example as a one-off job bootstrapped into `gui/<uid>`, or from a local terminal.
- The MacBook keychain contains a revoked Apple Development certificate, listed first by `security find-identity`. The Makefile skips revoked and expired identities.
- `SMAppService.status` reads correctly from an SSH session once the app is registered. Before registration it reports `notFound`.

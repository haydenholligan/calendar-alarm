#!/usr/bin/env python3
"""Watch Calendar Alarm's processes and memory, and check them against the budgets.

usage: scripts/ram-monitor.py [hours] [output-dir]

Polls once a second. Idle background checks usually finish in well under a
second, so most are never seen here; their cost comes from the app's own
per-run stats (`--status`). Anything that lives long enough to matter is
sampled with `footprint`.

Budgets:
  - a background check that does not ring exits within 80 s (75 s horizon + slack)
  - a background check that does not ring stays under 15 MB physical footprint
Ringing alarms and the Settings window are reported but not budgeted.

Writes events.jsonl (one line per process lifetime) and summary.txt (rewritten
every minute and at exit) to the output directory. Exits 1 if a budget was broken.
"""
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone

HOURS = float(sys.argv[1]) if len(sys.argv) > 1 else 24
OUT = os.path.expanduser(sys.argv[2] if len(sys.argv) > 2 else "~/Library/Logs/calendar-alarm-ram")
STATE = os.path.expanduser("~/Library/Application Support/com.corseapps.calendaralarm/state.json")
PROCESS_NAME = "CalendarAlarm"
BUDGET_MB = 15
MAX_IDLE_LIFETIME = 80
MB = 1024 * 1024

os.makedirs(OUT, exist_ok=True)


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def parse_time(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def pids():
    out = subprocess.run(["pgrep", "-x", PROCESS_NAME], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def args_of(pid):
    return subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()


def footprint(pid):
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    values = {}
    for key in ("phys_footprint", "phys_footprint_peak"):
        m = re.search(rf"{key}:\s+([\d.]+)\s*([KMG]?B)", out)
        if m:
            scale = {"B": 1, "KB": 1024, "MB": MB, "GB": 1024 * MB}[m.group(2)]
            values[key] = float(m.group(1)) * scale
    return values.get("phys_footprint"), values.get("phys_footprint_peak")


started = time.time()
deadline = started + HOURS * 3600
stats_before = load_state().get("stats") or {}
live = {}  # pid -> record
finished = []
violations = []
busy_seconds = 0.0
byte_seconds = 0.0
last_tick = started
last_summary = 0.0


def classify(record):
    if "--sync" not in record["args"]:
        return "settings/other"
    fired = load_state().get("fired", {}).values()
    rang = any(record["start"] - 1 <= parse_time(t) <= record["end"] + 1 for t in fired)
    return "sync-rang" if rang else "sync-waited"


def close(pid):
    record = live.pop(pid)
    record["end"] = time.time()
    record["lifetime_s"] = round(record["end"] - record["start"], 1)
    record["kind"] = classify(record)
    if record["kind"] == "sync-waited":
        if record["lifetime_s"] > MAX_IDLE_LIFETIME:
            violations.append(f"pid {pid} lived {record['lifetime_s']} s without ringing (limit {MAX_IDLE_LIFETIME} s)")
        if record["peak_mb"] and record["peak_mb"] > BUDGET_MB:
            violations.append(f"pid {pid} peaked at {record['peak_mb']:.1f} MB without ringing (limit {BUDGET_MB} MB)")
    finished.append(record)
    with open(os.path.join(OUT, "events.jsonl"), "a") as f:
        f.write(json.dumps({**record, "start": datetime.fromtimestamp(record["start"]).isoformat(timespec="seconds"),
                            "end": datetime.fromtimestamp(record["end"]).isoformat(timespec="seconds")}) + "\n")


def summary():
    now = time.time()
    elapsed = now - started
    after = load_state().get("stats") or {}
    runs = after.get("runs", 0) - stats_before.get("runs", 0)
    cpu = after.get("cpuMs", 0) - stats_before.get("cpuMs", 0)
    lines = [
        f"Calendar Alarm RAM monitor — {datetime.now().isoformat(timespec='seconds')}",
        f"watched:                 {elapsed / 3600:.2f} h (of {HOURS:g} h)",
        f"time with no process:    {100 * (1 - busy_seconds / elapsed):.3f} %" if elapsed else "",
        f"time-weighted average:   {byte_seconds / elapsed / MB:.4f} MB" if elapsed else "",
        f"idle checks (app stats): {runs} runs, {cpu / runs:.0f} ms CPU avg, "
        f"{after.get('peakFootprintBytes', 0) / MB:.1f} MB peak since {after.get('since', '?')}" if runs > 0
        else "idle checks (app stats): none recorded yet",
    ]
    for kind in ("sync-waited", "sync-rang", "settings/other"):
        rs = [r for r in finished if r["kind"] == kind]
        if rs:
            peak = max((r["peak_mb"] or 0) for r in rs)
            longest = max(r["lifetime_s"] for r in rs)
            lines.append(f"{kind + ':':24} {len(rs)} seen, longest {longest} s, peak {peak:.1f} MB")
    if live:
        lines.append(f"alive now:               {', '.join(str(p) for p in live)}")
    lines.append("budget: OK" if not violations else "budget: BROKEN\n  " + "\n  ".join(violations))
    text = "\n".join(l for l in lines if l) + "\n"
    with open(os.path.join(OUT, "summary.txt"), "w") as f:
        f.write(text)
    return text


def stop(*_):
    global deadline
    deadline = 0


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

while time.time() < deadline:
    now = time.time()
    current = set(pids())
    for pid in list(live):
        if pid not in current:
            close(pid)
    if current:
        busy_seconds += now - last_tick
    for pid in current:
        record = live.setdefault(pid, {"pid": pid, "args": args_of(pid), "start": now, "peak_mb": None})
        fp, peak = footprint(pid)
        if fp is not None:
            byte_seconds += fp * (now - last_tick)
        if peak is not None:
            record["peak_mb"] = max(record["peak_mb"] or 0, peak / MB)
    last_tick = now
    if now - last_summary >= 60:
        summary()
        last_summary = now
    time.sleep(1)

for pid in list(live):
    close(pid)
print(summary(), end="")
sys.exit(1 if violations else 0)

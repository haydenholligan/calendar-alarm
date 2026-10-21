import CalendarAlarmCore
import Foundation

/// `--status`. Reports what the background check recorded rather than asking
/// EventKit directly: from Terminal, macOS attributes Calendar access to the
/// terminal app, not to Calendar Alarm.
enum Status {
    static func print() {
        let store = Store.standard
        let state = store.loadState()
        let config = store.loadConfig()
        func time(_ date: Date?) -> String {
            guard let date else { return "never" }
            return "\(date.formatted(date: .abbreviated, time: .standard)) (\(date.formatted(.relative(presentation: .numeric))))"
        }
        var lines = [
            "background agent:  \(Agent.describe(Agent.service.status))",
            "calendar access:   \(state.calendarAccess ?? "unknown (no background check yet)")",
            "last check:        \(time(state.lastSync))",
            "events in window:  \(state.lastEventCount.map(String.init) ?? "-")",
            "next alarm:        \(state.nextAlarm.map { time($0) } ?? "none in the next 2 hours")",
            "pending snoozes:   \(state.snoozes.count)",
            "pending tests:     \(state.testAlarms.count)",
            "lead minutes:      \(config.leadMinutes.map(String.init).joined(separator: ", "))",
            "config:            \(store.configURL.path)",
        ]
        if let error = state.lastError { lines.append("last error:        \(error)") }
        if let s = state.stats, s.runs > 0 {
            let mb = { (bytes: UInt64) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
            lines += [
                "idle runs:         \(s.runs) since \(time(s.since))",
                "  cpu per run:     \(s.cpuMs / s.runs) ms avg",
                "  wall per run:    \(s.wallMs / s.runs) ms avg",
                "  peak footprint:  \(mb(s.peakFootprintBytes)) max, \(mb(s.lastFootprintBytes)) last",
            ]
        }
        Swift.print(lines.joined(separator: "\n"))
    }
}

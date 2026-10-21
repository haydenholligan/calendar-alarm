import CalendarAlarmCore
import Darwin
import Foundation

/// The `--sync` mode run by the LaunchAgent every 60 seconds.
///
/// Each run reads upcoming events, and if an alarm falls before the next run it
/// stays alive, waits, re-checks the event and rings. Otherwise it exits at once.
@MainActor
enum Sync {
    /// Slightly longer than the agent's StartInterval, so consecutive runs overlap.
    static let horizon: TimeInterval = 75

    static func run() -> Never {
        let store = Store.standard
        let started = Date()
        guard (try? store.acquireRunLock()) != nil else {
            // Another sync owns the schedule (for example, it is ringing).
            exit(0)
        }
        while true {
            switch nextAction(store: store) {
            case .idle:
                recordStats(store: store, started: started)
                exit(0)
            case .wait(let until):
                Thread.sleep(until: until)
            case .ring(let alarms):
                AlarmPresenter.runApp(alarms: alarms, store: store)
            }
        }
    }

    /// Read events, plan, and record any alarms about to ring as settled.
    static func nextAction(store: Store) -> Planner.Action {
        let now = Date()
        let config = store.loadConfig()
        let status = CalendarReader.status
        var occurrences: [Occurrence] = []
        if status == .fullAccess {
            let maxLead = TimeInterval((config.leadMinutes.max() ?? 0) * 60)
            occurrences = CalendarReader.occurrences(
                from: now.addingTimeInterval(-6 * 3600),
                to: now.addingTimeInterval(2 * 3600 + maxLead),
                config: config
            )
        }
        do {
            return try store.updateState { state in
                state.prune(now: now, config: config)
                let alarms = Planner.alarms(occurrences: occurrences, config: config, state: state)
                let action = Planner.next(now: now, alarms: alarms, state: state, config: config, horizon: horizon)
                if case .ring(let due) = action {
                    for alarm in due { state.settle(alarm, at: now) }
                }
                state.nextAlarm = Planner.upcoming(now: now, alarms: alarms, state: state)
                state.lastSync = now
                state.calendarAccess = CalendarReader.describe(status)
                state.lastEventCount = status == .fullAccess ? occurrences.count : nil
                state.lastError = status == .fullAccess ? nil : "Calendar access is \(CalendarReader.describe(status)). Open Calendar Alarm to fix."
                return action
            }
        } catch {
            // Without state we cannot dedupe, so do not ring; the next run retries.
            FileHandle.standardError.write(Data("calendar-alarm: state update failed: \(error)\n".utf8))
            return .idle
        }
    }

    static func recordStats(store: Store, started: Date) {
        let usage = ResourceUsage.current()
        let wallMs = Int(Date().timeIntervalSince(started) * 1000)
        try? store.updateState { state in
            if state.stats == nil { state.stats = RunStats(since: started) }
            state.stats?.record(cpuMs: usage.cpuMs, wallMs: wallMs, peakFootprintBytes: usage.peakFootprint)
        }
    }
}

struct ResourceUsage {
    var cpuMs: Int
    var footprint: UInt64
    var peakFootprint: UInt64

    static func current() -> ResourceUsage {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Int((usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000)

        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return ResourceUsage(cpuMs: cpu, footprint: 0, peakFootprint: 0) }
        return ResourceUsage(cpuMs: cpu, footprint: info.phys_footprint, peakFootprint: UInt64(max(0, info.ledger_phys_footprint_peak)))
    }
}
